---
aliases:
  - DNS resolution
  - DNS caching
  - Разрешение DNS-имён
tags:
  - область/основы-cs
  - тема/сети
  - механизм/dns
статус: проверено
---

# DNS resolution и caching

## TL;DR

DNS — распределённая делегированная база записей, а не один каталог `имя → IP`. Обычно приложение вызывает stub resolver, тот отправляет recursive query рекурсивному резолверу, а резолвер при cache miss сам проходит цепочку root → TLD → authoritative server с помощью iterative queries. Referral сообщает, где искать дальше; authoritative answer сообщает данные зоны.

Cache хранит не только положительные RRsets, но и отрицательные ответы и кратковременные failures. TTL задаёт срок повторного использования конкретного RRset, но не гарантирует мгновенное переключение трафика: кэш существует на нескольких уровнях, а уже открытые соединения переживают DNS-запись. DNS также не проверяет readiness или здоровье процесса — эту границу раскрывает [[40 Распределённые системы/Service discovery|service discovery]].

## Область применимости

- Базовая модель соответствует классическому DNS из RFC 1034/1035 с уточнениями RFC 2181, 2308, 6891, 7766, 8767, 9499, 9520 и 9715, проверенными 2026-07-18.
- DNSSEC рассматривается как проверка происхождения и целостности DNS-данных по RFC 4033, без разбора управления ключами и алгоритмов валидации.
- Вне scope: настройка конкретного resolver, DNS over TLS/HTTPS, multicast DNS и использование DNS как полноценного registry API.

## Ментальная модель

У разрешения имени есть две разные цепочки:

```text
application
  -> stub resolver
  -> recursive resolver/cache
  -> root authoritative
  -> TLD authoritative
  -> zone authoritative
```

Первая стрелка обычно означает **recursive query**: stub просит конечный ответ или ошибку. Дальше recursive resolver делает **iterative queries**: каждый authoritative server либо отвечает за свою зону, либо возвращает referral — NS RRset более близкой делегации и, при необходимости, glue addresses.

Полезные инварианты:

1. Единица обычного положительного кэша — RRset с ключом `(owner name, type, class)`, а не «домен целиком». `A`, `AAAA` и `CNAME` имеют независимые TTL.
2. Владелец authoritative zone публикует TTL. Кэш уменьшает его с течением времени, может удалить запись раньше, но не должен выдавать неистёкшие данные дольше исходного TTL. Исключение — явно включённый serve-stale по RFC 8767 при невозможности обновить запись.
3. `NXDOMAIN`, `NODATA` и `SERVFAIL` означают разные наблюдаемые состояния: имени нет; у имени нет запрошенного типа; разрешение временно не удалось.
4. DNS-ответ задаёт кандидатов для соединения. Он не обещает, что endpoint готов, жив или подходит конкретному запросу.

## Как устроено

### Делегация, referral и CNAME

Root zone делегирует TLD, TLD — дочернюю зону. Referral обычно содержит NS RRset делегированной зоны. Если имя nameserver находится внутри самой делегируемой зоны, родитель добавляет glue `A`/`AAAA`, чтобы resolver не попал в циклическую зависимость «адрес NS можно узнать только у этого NS». Glue помогает продолжить поиск, но не становится более авторитетным, чем данные самой дочерней зоны.

Authoritative server отвечает authoritative только за обслуживаемую зону. Recursive resolver, напротив, собирает конечный результат от имени клиента и кэширует промежуточные делегации и ответы. Один процесс может реализовывать обе роли, но доверие к конкретному response определяется данными и зоной, а не названием продукта.

`CNAME` говорит, что owner name является alias другого canonical name. Для запроса не типа `CNAME` resolver следует цепочке до RRset нужного типа. Каждый link кэшируется со своим TTL; истечение конечного `A` не обязано инвалидировать ещё свежий `CNAME`. Зацикленная CNAME-цепочка остаётся ошибкой: найденный первый alias ещё не даёт конечного ответа.

### Положительное, отрицательное и failure caching

Положительный ответ кэшируется на оставшийся TTL его RRset. Повторный ответ обязан показывать уменьшенный TTL, поэтому downstream cache не начинает исходный срок заново. Разные RRsets одного ответа могут истечь в разное время.

RFC 2308 разделяет два отрицательных результата:

- `NXDOMAIN` (`RCODE=3`) означает, что QNAME не существует; cache key не включает QTYPE;
- `NODATA` — `NOERROR` с пустым answer для запрошенного типа при существующем имени; cache key включает QTYPE.

Authoritative negative response передаёт SOA зоны в authority section. Negative TTL равен меньшему из SOA TTL и поля SOA MINIMUM. Без подходящего SOA такой negative response не следует распространять как долго живущее доказательство отсутствия.

`SERVFAIL`, timeout авторитетных серверов и DNSSEC validation failure не означают отсутствия имени. RFC 9520 требует кратко кэшировать resolution failures, чтобы множество клиентов не повторяло один и тот же запрос к неисправной делегации: минимум 1 секунда, максимум 5 минут, с ключом и политикой, зависящими от вида failure. Это защита control-plane capacity, но более длинное значение замедляет восстановление.

Serve-stale по RFC 8767 не отменяет смысл TTL. Recursive resolver **может** сохранить истёкшие данные и применить их как аварийный fallback, когда свежий ответ не удалось получить. В описанном RFC методе сначала пытаются обновить данные; после client response timer допустимо вернуть stale и продолжить refresh. В ответе каждому stale RR задают TTL больше нуля, рекомендуемое значение — 30 секунд. Это осознанный обмен freshness на availability, а не разрешение всегда игнорировать TTL.

### UDP, TCP и EDNS(0)

DNS использует и UDP, и TCP на порту 53. Исторический DNS без EDNS ограничивает UDP message 512 октетами. EDNS(0) добавляет OPT pseudo-RR, через который requester объявляет максимальный UDP payload, который способен принять. Это не доказывает, что весь сетевой путь перенесёт пакет без fragmentation.

Если UDP-ответ не помещается, server выставляет `TC` (truncated), а resolver повторяет запрос по TCP. RFC 7766 требует поддержки и UDP, и TCP у полноценной DNS-реализации; TCP является допустимым transport, а не только редким аварийным обходом. Firewall, который пропускает UDP/53 и блокирует TCP/53, поэтому ломает большие ответы, DNSSEC и некоторые referrals. RFC 9715 как Informational-рекомендация предлагает ограничивать DNS/UDP payload 1400 октетами; 1232 октета — консервативное значение для путей с минимальным IPv6 MTU.

### Защита кэша

Resolver принимает response только для ожидаемого outstanding query: должны совпасть question, query ID, адреса и порты. Непредсказуемые query ID и source port увеличивают пространство, которое атакующему приходится угадать. Bailiwick policy не даёт referral безусловно внедрить произвольные records из посторонней зоны; дополнительные данные принимаются только в контексте делегации и с соответствующим уровнем доверия.

DNSSEC добавляет проверяемую цепочку доверия через `DS`, `DNSKEY`, `RRSIG` и authenticated denial of existence. Validating resolver различает `secure`, `insecure` и `bogus` данные; `bogus` обычно приводит к `SERVFAIL`, а не к подстановке неподтверждённого адреса. DNSSEC не шифрует запросы, не скрывает имена и не делает authoritative server доступным.

## Пример или трассировка

Пусть учебная DNS-иерархия содержит фиктивную зону со следующими данными:

```text
api.shop.example.   60 IN CNAME edge.shop.example.
edge.shop.example.  20 IN A     192.0.2.10
shop.example.      300 IN SOA   ns1.shop.example. hostmaster.shop.example. 1 3600 600 86400 30
```

Cache recursive resolver пуст, stub запрашивает `A api.shop.example`.

1. Resolver спрашивает root и получает referral к authoritative servers зоны `example`; затем получает referral к `shop.example`.
2. Authoritative server возвращает `CNAME api.shop.example → edge.shop.example` с TTL 60 и `A edge.shop.example = 192.0.2.10` с TTL 20.
3. Через 15 секунд повторный клиент получает те же RRsets из cache с остатками примерно 45 и 5 секунд. Исходные 60 и 20 не начинаются заново.
4. Через 25 секунд `CNAME` ещё свежий, а `A` уже истёк. Resolver использует cached alias, но заново запрашивает `A edge.shop.example`.
5. Запрос `AAAA edge.shop.example` может получить `NOERROR` без `AAAA` в answer, но с SOA в authority: это кэшируемый NODATA для конкретного типа. Запрос заведомо отсутствующего `missing.shop.example` получает NXDOMAIN для имени. При указанном SOA negative TTL составит `min(300, 30) = 30` секунд.
6. Если authoritative servers не отвечают, результат — failure, а не NXDOMAIN. Resolver кратко кэширует failure по RFC 9520; при заранее сохранённом истёкшем `A` и включённом serve-stale он может временно вернуть stale address.

Наблюдаемый результат: один логический lookup использует независимо живущие данные делегации, alias и address. Изменение `A` не требует изменения `CNAME`, а DNS outage не доказывает отсутствия имени.

## Trade-offs

Низкий TTL ускоряет наблюдение изменений, но увеличивает число запросов, зависимость от authoritative availability и вероятность одновременного refresh у многих caches. Высокий TTL уменьшает latency и нагрузку, зато дольше удерживает старый адрес. TTL выбирают вместе с периодом миграции, жизнью connection pools и возможностью старого endpoint продолжать обслуживание.

Локальный caching resolver сокращает latency и агрегирует запросы, но создаёт общую stale/failure boundary. Прямое обращение каждого процесса к внешней иерархии дублирует работу и не заменяет корректный recursive resolver.

Serve-stale повышает availability во время DNS outage, но может направлять трафик на уже выведенный адрес. DNSSEC защищает целостность и происхождение данных, но требует исправной цепочки подписей и увеличивает размер ответов; ошибки ключей превращают существующее имя в `SERVFAIL` для validating clients.

## Типичные ошибки

### `SERVFAIL` кэшируют как «имени нет»

- **Неверное предположение:** любой пустой результат разрешения равен NXDOMAIN.
- **Симптом:** приложение надолго считает сервис отсутствующим после краткого DNS outage.
- **Причина:** временный failure потерял свой RCODE/класс и попал в negative cache с TTL отсутствия имени.
- **Исправление:** различать NXDOMAIN, NODATA, timeout, validation failure и SERVFAIL; применять RFC 2308/9520 с отдельными ключами и сроками.

### При изменении записи учитывают только authoritative TTL

- **Неверное предположение:** через TTL все клиенты гарантированно используют новый IP.
- **Симптом:** часть трафика продолжает идти на старый endpoint после DNS-переключения.
- **Причина:** application cache применяет собственную политику, resolver использует serve-stale или уже открытое pooled connection пережило DNS TTL.
- **Исправление:** заранее снизить TTL, измерить фактические cache policies, оставить старый endpoint на drain window и учитывать [[20 Бэкенд/Пулы соединений и keep-alive|жизнь соединений]].

### DNS используют как health check

- **Неверное предположение:** наличие адреса означает готовность процесса обслужить запрос.
- **Симптом:** клиенты получают connect errors и timeouts до истечения TTL после падения instance.
- **Причина:** authoritative data описывает имя и topology, но не наблюдает readiness конкретного path.
- **Исправление:** отделить discovery от readiness/passive health и выбирать eligible endpoint через [[10 Основы CS/Балансировка сетевой нагрузки|балансировку сетевой нагрузки]].

### Разрешают только UDP/53

- **Неверное предположение:** DNS всегда помещается в один маленький UDP datagram.
- **Симптом:** короткие ответы работают, а DNSSEC или крупные RRsets стабильно завершаются timeout.
- **Причина:** truncated response требует TCP, либо IP fragments теряются на path.
- **Исправление:** поддерживать UDP и TCP, корректно обрабатывать `TC`, EDNS и уменьшение advertised payload.

### Доверяют всем additional records

- **Неверное предположение:** любой RR в response можно положить в cache с одинаковым доверием.
- **Симптом:** forged referral отравляет адрес постороннего имени.
- **Причина:** проигнорированы matching outstanding query, bailiwick и различие authoritative/additional data.
- **Исправление:** проверять tuple запроса, рандомизировать ID/port, применять bailiwick policy и DNSSEC validation там, где нужна криптографическая проверка.

## Когда применять

Эта модель нужна при диагностике «имя иногда не находится», DNS failover, смене адресов, выборе TTL, настройке firewall и анализе latency до установления соединения. Для внутреннего сервиса сначала определяют, что возвращает имя — stable proxy/VIP или список instances, — а затем отдельно проектируют discovery, readiness, балансировку и draining.

В трассировке записывают QNAME/QTYPE, resolver, cache hit/miss, response code, authoritative flag, CNAME chain, оставшийся TTL, transport, `TC`, DNSSEC status и время каждой итерации. Без этих полей `DNS error` смешивает отсутствие данных, отказ authority, транспортную проблему и ошибку валидации.

## Источники

- [RFC 1034 — Domain Names: Concepts and Facilities](https://www.rfc-editor.org/rfc/rfc1034.html) — IETF, RFC 1034, ноябрь 1987, проверено 2026-07-18.
- [RFC 1035 — Domain Names: Implementation and Specification](https://www.rfc-editor.org/rfc/rfc1035.html) — IETF, RFC 1035, ноябрь 1987, проверено 2026-07-18.
- [RFC 2181 — Clarifications to the DNS Specification](https://www.rfc-editor.org/rfc/rfc2181.html) — IETF, RFC 2181, июль 1997, проверено 2026-07-18.
- [RFC 2308 — Negative Caching of DNS Queries](https://www.rfc-editor.org/rfc/rfc2308.html) — IETF, RFC 2308, март 1998, проверено 2026-07-18.
- [RFC 4033 — DNS Security Introduction and Requirements](https://www.rfc-editor.org/rfc/rfc4033.html) — IETF, RFC 4033, март 2005, проверено 2026-07-18.
- [RFC 5452 — Measures for Making DNS More Resilient against Forged Answers](https://www.rfc-editor.org/rfc/rfc5452.html) — IETF, RFC 5452, январь 2009, проверено 2026-07-18.
- [RFC 6891 — Extension Mechanisms for DNS (EDNS(0))](https://www.rfc-editor.org/rfc/rfc6891.html) — IETF, RFC 6891, апрель 2013, проверено 2026-07-18.
- [RFC 7766 — DNS Transport over TCP: Implementation Requirements](https://www.rfc-editor.org/rfc/rfc7766.html) — IETF, RFC 7766, март 2016, проверено 2026-07-18.
- [RFC 9499 — DNS Terminology](https://www.rfc-editor.org/rfc/rfc9499.html) — IETF, BCP 219 / RFC 9499, март 2024; заменяет RFC 8499, проверено 2026-07-18.
- [RFC 8767 — Serving Stale Data to Improve DNS Resiliency](https://www.rfc-editor.org/rfc/rfc8767.html) — IETF, RFC 8767, март 2020, проверено 2026-07-18.
- [RFC 9520 — Negative Caching of DNS Resolution Failures](https://www.rfc-editor.org/rfc/rfc9520.html) — IETF, RFC 9520, декабрь 2023, проверено 2026-07-18.
- [RFC 9715 — IP Fragmentation Avoidance in DNS over UDP](https://www.rfc-editor.org/rfc/rfc9715.html) — IETF, Informational RFC 9715, январь 2025, проверено 2026-07-18.
