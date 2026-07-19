---
aliases:
  - Server-Side Request Forgery
  - SSRF
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/сети
статус: проверено
---

# SSRF

## TL;DR

Server-Side Request Forgery (SSRF) появляется, когда внешний субъект управляет тем, куда backend установит соединение. Запрос уходит с сетевой позиции и полномочиями сервиса, поэтому недоступный извне internal endpoint, loopback listener, metadata service или другой protocol handler внезапно оказывается достижим через публичное API.

Защита строится вокруг **outbound capability**. Для фиксированных интеграций клиент передаёт business identifier, а сервер выбирает endpoint из allowlist. Если бизнес требует произвольные внешние URL, приложение парсит URL структурно, ограничивает scheme/port, разрешает DNS, проверяет все адреса, привязывает dial к проверенному адресу, повторяет policy на каждом redirect и ставит независимый egress firewall/proxy. Ответ, время, размер и число параллельных fetch тоже ограничиваются.

Проверка исходной строки URL один раз не доказывает безопасность: значение меняется при decoding, relative resolution, DNS, redirect и proxy routing.

## Область применимости

Заметка рассматривает CWE-918 в редакции CWE 4.20 от 2026-04-30 и HTTP(S)-клиенты backend-сервисов: URL preview, avatar/image import, webhook validation, document conversion и server-side integration callbacks.

Вне scope остаются подробные техники эксплуатации, сетевой DDoS и XXE как самостоятельная уязвимость. SSRF не ограничен HTTP, но практическая модель ниже запрещает все схемы, кроме явно нужных `https` и, при обосновании, `http`.

## Ментальная модель

Backend с HTTP client — это прокси с доверенной сетевой позицией:

```text
external caller
    -> public API
    -> backend fetcher
       identity: service account
       reachability: service network + loopback + configured proxies
       credentials: outbound headers, client certificate, ambient cloud identity
    -> chosen target
```

Обычная [[20 Бэкенд/Аутентификация и авторизация на уровне API|авторизация API]] отвечает, кому разрешено вызвать `fetch`. SSRF policy отвечает на другой вопрос: **какой сетевой ресурс разрешено сделать объектом этого вызова**. Право «создать webhook» не означает право превратить сервис в универсальный network client.

Полезно мыслить не строкой URL, а цепочкой преобразований:

```text
raw input
  -> URL parser
  -> scheme + authority + host + port
  -> DNS A/AAAA results
  -> selected socket address
  -> proxy / route
  -> redirects
  -> response parser
```

Security policy должна оставаться истинной после каждого шага.

## Как устроено

### Два разных продукта

OWASP разделяет два случая.

**Назначение известно заранее.** Например, сервис отправляет данные в два внутренних API. Клиенту не нужен полный URL. Он передаёт `integration_id=crm_eu`, а сервер хранит `(scheme, host, port, path prefix, credentials)` в доверенной конфигурации. Это самая сильная модель: адрес не принадлежит user-controlled data plane.

**Назначение произвольное, но должно быть внешним.** Так работают webhooks и URL preview. Здесь allowlist всех доменов невозможен; нужен специализированный fetcher с parser, resolver, dialer и egress policy. Blocklist остаётся менее надёжной, потому что special-purpose ranges и способы адресации меняются, а DNS и redirects создают новые targets.

Нельзя незаметно смешивать модели. Endpoint «проверить URL» с произвольным host не должен использовать тот же client и network namespace, что client внутренних control-plane API.

### URL parsing и нормализация

RFC 3986 задаёт структуру URI и resolution relative references. Security-код использует один стандартный parser и проверяет компоненты, а не regex над строкой.

Минимальная policy для внешнего fetch:

- разрешены только точные схемы, обычно `https`;
- authority обязан содержать host; userinfo и fragment отвергаются, если бизнес их не использует;
- port либо отсутствует и берётся из scheme, либо входит в малый allowlist;
- host canonicalized библиотекой и не сравнивается через substring или suffix без границы label;
- URL декодируется на определённом слое ровно столько раз, сколько задаёт protocol; повторное «на всякий случай» decoding создаёт parser differential;
- client не регистрирует `file`, local IPC или другие protocol handlers для внешних URL.

Даже идеально распарсенный `https` URL ещё не безопасен: доменное имя — отложенное решение о socket address.

### DNS и привязка соединения

Fetcher разрешает A и AAAA через контролируемый resolver и проверяет **каждый** полученный адрес по сетевой policy. Нельзя проверить только первый result: transport способен выбрать другой. Политика обычно запрещает loopback, link-local, private/internal routes, unspecified, multicast и special-purpose address space; точный набор берут из актуальных IANA IPv4/IPv6 registries и собственной routing inventory.

Классификатор работает с разобранным IP-объектом, а не с текстовым prefix. IPv4, IPv6 и IPv4-mapped IPv6 приводятся к одной модели до проверки: иначе одно и то же назначение получает разные строковые представления и обходит policy.

Проверка «имя в момент проверки разрешилось во внешний IP» с последующим обычным dial по имени имеет TOCTOU: resolver transport может получить другой ответ. Строгая реализация выбирает один из уже проверенных IP и соединяется именно с ним, сохраняя исходный hostname для HTTP authority/`Host`, TLS Server Name и проверки сертификата. Если выполняется retry с новым resolve, policy запускается снова.

DNS pinning/rebinding — частный случай смены mapping. Кэширование ответа не должно быть единственной защитой; нужен invariant на фактически выбранном destination address и сетевом route.

### Redirects и proxy

Redirect создаёт новый URL, следовательно, новый security decision. Безопасный default для фиксированных интеграций — redirects выключены. Если они нужны, каждый hop проходит полный pipeline: parse, scheme/port policy, DNS, address check и dial binding. Число hops ограничено.

Нельзя автоматически переносить `Authorization`, cookies, client-specific headers или signed request body на новый origin. Inbound credentials вообще не копируют в user-selected outbound request. Credentials выбираются только после того, как destination сопоставлен с доверенной integration policy.

Environment proxy тоже меняет фактический маршрут. Dedicated fetcher либо отключает неявные proxy settings, либо использует контролируемый egress proxy, который повторно применяет destination policy. Проверенный public IP бесполезен, если произвольный proxy способен обратиться во внутреннюю сеть от своего имени.

### Сетевая граница

Application validation уменьшает ошибки, но parser bug или забытый code path не должны давать полный egress. Network policy разрешает fetcher workload только внешний egress через proxy/DNS и явно нужные destinations. Internal control plane, node-local services и metadata network закрываются независимо от URL-кода.

Полезная архитектура выносит fetch в отдельный сервис/worker:

- без production secrets и internal service credentials;
- в отдельном network segment;
- с read-only temporary storage;
- с ограниченными CPU, memory, response bytes, redirects, decompression и concurrency;
- с журналом resolved IP, selected route, final URL category и policy reason без полного чувствительного URL query.

Это не отменяет проверки URL, но уменьшает последствия обхода.

### Ответ тоже недоверенный

SSRF-защита не заканчивается на connect. Внешний сервер управляет status, headers, body, compression и временем передачи. Fetcher ограничивает connect/read/total timeout, максимальный compressed и decompressed size, content type, число redirects и concurrent fetches. Эти budgets связываются с [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline запроса]].

Raw response не следует безусловно отражать клиенту: он может содержать internal error detail, активный content или данные другого protocol. Parser извлекает только нужную business value.

## Сквозной пример: импорт изображения с redirect

Сервис принимает `https://images.example.test/avatar/42`. Домены `.test` и адреса documentation ranges используются только для безопасной трассировки.

1. Parser получает `scheme=https`, `host=images.example.test`, default port `443`. Userinfo отсутствует.
2. Контролируемый DNS возвращает `192.0.2.40`. Адрес относится к тестовому окружению и явно разрешён policy этого примера. Dialer соединяется с **этим** IP, но проверяет TLS certificate для `images.example.test`.
3. Ответ содержит redirect на `https://storage.example.test/objects/a42`. Fetcher не следует ему автоматически: заново парсит URL, разрешает DNS и проверяет destination.
4. DNS второго host возвращает `127.0.0.1`. Loopback запрещён. Соединение не создаётся, credentials не отправляются.
5. API возвращает стабильную доменную ошибку `remote_target_not_allowed`; audit event содержит request ID, исходный host, redirect hop, address class и reason code. Query и response body в лог не попадают.

Наблюдаемый результат: первый допустимый hop не «легализует» второй. Policy применяется к фактическому адресу каждого соединения, поэтому redirect не превращает fetcher в доступ к локальному listener.

## Trade-offs и альтернативы

### Identifier-to-endpoint mapping или полный URL

Server-side mapping почти исключает SSRF для фиксированного набора интеграций и позволяет безопасно выбирать credentials. Полный URL даёт продуктовую гибкость, но требует отдельного fetch subsystem и остаётся зависимым от DNS/registry/network policy. Если пользователь выбирает только известную систему, полный URL — неоправданная capability.

### Allowlist или запрет special ranges

Allowlist host/IP/port проще доказать и тестировать. Blocklist нужна для открытых webhooks, но требует актуальных IANA registries, учёта собственной сети, всех A/AAAA answers, redirects и proxies. Это осознанно более слабый контракт.

### Проверка в приложении или egress proxy

Приложение знает business context и может отличить `crm_eu` от произвольного URL. Egress proxy видит фактический route и централизует policy, но может потерять исходный tenant/operation и TLS-level context. Надёжная схема использует оба слоя и передаёт proxy аутентифицированную workload identity.

### DNS pinning или resolve на каждый запрос

Pinning проверенного IP на короткую операцию закрывает TOCTOU, но хуже переносит legitimate failover. Повторный resolve поддерживает динамику, зато каждый retry становится новым policy decision. Нельзя кэшировать «домен разрешён» отдельно от конкретных адресов и срока.

### Synchronous fetch или асинхронный worker

Синхронный путь проще для клиента, но внешний target удерживает request worker и connection. Асинхронный bounded worker изолирует latency и позволяет quarantine результата; появляется очередь и eventual completion. Для untrusted arbitrary URL второй вариант обычно безопаснее.

## Типичные ошибки

### Проверяют только строку host

- **Неверное предположение:** разрешённое доменное имя всегда ведёт на внешний адрес.
- **Симптом:** тот же URL проходит validation, но соединение уходит в запрещённую сеть.
- **Причина:** DNS mapping изменился между проверкой и dial либо transport выбрал непроверенный A/AAAA result.
- **Исправление:** проверять все answers и привязывать dial к выбранному проверенному IP; повторять policy при новом resolve.

### Разрешают redirects по умолчанию

- **Неверное предположение:** безопасность первого URL распространяется на redirect chain.
- **Симптом:** initial host разрешён, final connection запрещён policy.
- **Причина:** HTTP client самостоятельно создал новый request без повторной проверки.
- **Исправление:** выключить redirects или revalidate каждый hop и не переносить credentials между origins.

### Сравнивают URL regex или substring

- **Неверное предположение:** `endsWith("example.com")` доказывает принадлежность домену.
- **Симптом:** parser и security-checker видят разные authority/host.
- **Причина:** проверяется текстовое представление, а не структурные компоненты и label boundary.
- **Исправление:** один стандартный parser, canonical host и exact allowlist; не принимать полный URL там, где хватает identifier.

### Считают `https` достаточной защитой

- **Неверное предположение:** TLS делает destination доверенным.
- **Симптом:** backend устанавливает защищённое соединение с нежелательным internal target.
- **Причина:** TLS аутентифицирует выбранный peer, но не решает, было ли приложению разрешено его выбирать.
- **Исправление:** destination authorization до connect, затем обычная проверка сертификата.

### Ограничивают URL, но оставляют полный egress

- **Неверное предположение:** application validator никогда не обходится.
- **Симптом:** новый code path, parser bug или другой scheme получает доступ ко всей service network.
- **Причина:** отсутствует независимая network boundary.
- **Исправление:** dedicated fetcher identity, egress proxy/firewall и закрытые internal routes.

### Не ограничивают ответ

- **Неверное предположение:** SSRF — только выбор адреса.
- **Симптом:** memory/CPU/connection pool исчерпываются большим, медленным или сильно сжатым ответом.
- **Причина:** недоверенный peer управляет resource cost после разрешённого connect.
- **Исправление:** bounded time, bytes, decompression, redirects и concurrency согласно [[10 Основы CS/Исчерпание ресурсов процесса|модели ресурсов процесса]].

## Когда применять

SSRF review обязателен для любого feature, где внешнее значение влияет на scheme, host, port, proxy, redirect или имя network service. Ищут не только прямой `HTTP GET`: SDK cloud/storage, image/PDF converters, XML parsers, webhook test buttons и importers тоже способны инициировать сеть.

Практическое правило: покажите фактический socket destination и policy, которая разрешила его **в момент соединения**. Затем покажите, что следующий redirect, retry и proxy route проходят ту же проверку. Если ответ ограничивается только исходной строкой URL, доказательство неполно.

## Источники

- [CWE-918: Server-Side Request Forgery](https://cwe.mitre.org/data/definitions/918.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [Server-Side Request Forgery Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [RFC 3986: Uniform Resource Identifier — Generic Syntax](https://datatracker.ietf.org/doc/html/rfc3986) — IETF, RFC 3986, январь 2005, проверено 2026-07-18.
- [IPv4 Special-Purpose Address Space](https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml) — IANA, актуальный registry, проверено 2026-07-18.
- [IPv6 Special-Purpose Address Space](https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml) — IANA, актуальный registry, проверено 2026-07-18.
- [OWASP Application Security Verification Standard](https://owasp.org/www-project-application-security-verification-standard/) — OWASP, ASVS 5.0.0 от 2025-05-30, проверено 2026-07-18.
