---
aliases:
  - Rate limiting
  - Quotas
  - Abuse prevention
tags:
  - область/бэкенд
  - тема/http
  - тема/безопасность
  - тема/устойчивость
статус: проверено
---

# Rate limiting, quotas и abuse prevention

## TL;DR

Rate limit ограничивает скорость поступления работы за короткий интервал. Quota ограничивает накопленное потребление за более длинный период или выделяет клиенту конечный объём ресурса. Concurrency limit решает третью задачу: сколько дорогих операций одновременно удерживают ресурсы.

Корректный limiter сначала определяет identity, scope и стоимость запроса, затем атомарно принимает либо отклоняет его. Token bucket допускает контролируемый burst и удерживает среднюю скорость через refill. `429 Too Many Requests` сообщает о превышении клиентского ограничения; временная нехватка capacity самого сервиса ближе к `503 Service Unavailable` и [[40 Распределённые системы/Load shedding|load shedding]].

Abuse prevention шире. Атакующий может распределить допустимые действия по IP, аккаунтам и времени, не превысив ни один простой rate limit. Поэтому защита связывает многоуровневые limits с бизнес-инвариантами, сигналами риска, step-up проверкой и расследуемым audit trail. Limiter принимает детерминированное решение о бюджете; risk engine оценивает поведение и не должен незаметно подменять authorization.

## Область применимости

- HTTP-код `429` соответствует RFC 6585 от апреля 2012 года, `Retry-After` и `503` — RFC 9110 от июня 2022 года.
- Поля `RateLimit` и `RateLimit-Policy` рассматриваются по Internet-Draft `draft-ietf-httpapi-ratelimit-headers-11` от мая 2026 года. Это work in progress, а не опубликованный RFC.
- Token bucket показан по официальным документам AWS EC2 и Envoy 1.38.3.
- Authentication throttling сверяется с NIST SP 800-63B-4 от июля 2025 года. Его численные требования относятся к области действия стандарта, а не задают универсальный лимит для любого API.
- В scope входит application-level abuse: credential stuffing, scraping и злоупотребление дорогими или дефицитными операциями. Вне scope: тарифный биллинг, поглощение volumetric DDoS на сетевом периметре и доказательство справедливости конкретного глобального алгоритма.

## Ментальная модель

Limiter выдаёт разрешения на работу. Запросу нужен ключ вроде `(tenant, API, region)` и число разрешений, соответствующее его стоимости. Если разрешение есть, запрос проходит; если нет, сервис отказывает до выполнения дорогой части.

Нельзя сводить всё к «100 requests per second»:

- тысяча cache hits и тысяча тяжёлых exports имеют разную стоимость;
- сто быстрых запросов не равны ста медленным, которые одновременно держат connections;
- лимит на каждой из десяти replicas по 100 rps даёт системе до 1000 rps, а не глобальные 100;
- IP плохо описывает пользователя за NAT и легко меняется атакующим.

Поэтому контракт начинается с единицы измерения и области действия, а уже затем выбирается алгоритм.

## Как устроено

### Token bucket

У bucket есть capacity `B`, refill rate `r` tokens per second и текущее число tokens. Перед решением состояние обновляют:

```text
tokens = min(B, tokens + r * elapsed)
```

Если `tokens >= cost(request)`, стоимость вычитается и запрос проходит. Иначе он получает отказ либо ждёт в bounded queue, если ожидание входит в контракт.

Capacity задаёт burst. Refill rate задаёт устойчивую среднюю скорость. При `B=100` и `r=20/s` клиент может мгновенно потратить 100 tokens после простоя, но затем получает примерно 20 tokens в секунду. Если expensive operation стоит 5 tokens, limiter учитывает её отдельно от дешёвого чтения.

Leaky bucket обычно сглаживает выход почти до постоянной скорости и удобен перед чувствительным downstream. Fixed window прост, но даёт удвоенный burst на границе окон: клиент расходует весь лимит в конце одной секунды и ещё раз в начале следующей. Sliding window точнее приближает rolling rate, но хранит больше состояния или использует аппроксимацию.

### Identity, scope и policy

Ключ limiter выбирают по контролируемой сервером identity: tenant, credential, account, project, method, resource class. Пользовательский header без authentication нельзя считать надёжным ключом.

Policy должна отвечать на вопросы:

- лимит локален instance, region или глобален;
- burst общий для всех методов или разделён;
- запросы имеют одинаковую стоимость или resource units;
- что происходит при недоступности хранилища limiter: fail-open либо fail-closed;
- как долго хранится state высококардинальных ключей.

AWS EC2 использует request token buckets и отдельные resource token buckets для некоторых API. Это показательный случай: частота вызовов и количество создаваемых ресурсов — разные оси контроля.

### Abuse prevention поверх лимитов

Rate limit отвечает на вопрос «остался ли бюджет у этого ключа?». Abuse policy отвечает на другой вопрос: «похожа ли последовательность разрешённых действий на злоупотребление продуктом?». OWASP Automated Threats отделяет такие сценарии от эксплуатации одной программной уязвимости: credential stuffing использует штатный login, scraping читает доступные страницы, denial of inventory резервирует товар через корректный workflow.

Контроли располагают по разным осям, иначе обход одной identity снимает всю защиту:

- edge ограничивает анонимный source и поглощает дешёвый шум до application;
- authentication flow считает попытки по account/authenticator, а IP и device использует как дополнительные сигналы, чтобы distributed guessing не обходил счётчик;
- API применяет бюджеты по principal, tenant, action и resource cost, отдельно ограничивая concurrency и outstanding work;
- доменная модель ставит предел самому эффекту: число активных reservations, объём export, число promo redemptions или скорость изменения recovery attributes;
- risk engine коррелирует низкоскоростные события и выбирает delay, step-up authentication, challenge, review или block; решение и его reason code попадают в audit.

Один жёсткий account lockout создаёт denial of service для владельца. NIST SP 800-63B-4 поэтому допускает increasing delay, bot challenge и risk-based signals рядом с ограничением неудачных попыток. Конкретный порог выводят из entropy credential, цены false positive, recovery path и threat model. Для чувствительного эффекта лимит не заменяет [[20 Бэкенд/Аутентификация и авторизация на уровне API|проверку полномочий]].

### Локальный и глобальный limiter

Локальный token bucket дешёв и не добавляет сетевой hop. Его пропускная способность умножается на число replicas и меняется при autoscaling. Он подходит для защиты конкретного process или когда глобальный бюджет заранее разделён между instances.

Глобальный limiter даёт единый quota view, но создаёт горячий ключ, сетевую latency и новый failure mode. Частый компромисс — выдавать replicas короткие leases на часть глобального бюджета. Решения становятся быстрыми локально, но суммарный расход может временно превышать точную границу из-за уже выданных leases.

Любой distributed limiter имеет окно рассогласования. Требование «никогда не превысить ни на один request» обычно требует сериализованного решения и оплачивается latency и availability.

### HTTP-ответ и подсказки клиенту

RFC 6585 определяет `429 Too Many Requests`, но не навязывает способ считать запросы и идентифицировать клиента. Ответ может содержать `Retry-After`. Клиент всё равно должен добавить jitter: если миллионы callers получили одну секунду, точный повтор на границе создаст новую волну.

Draft RateLimit headers разделяет policy и текущее operational hint. Значение остатка не даёт SLA: сервер может изменить policy или отклонить запрос по другой причине. При одновременном `Retry-After` именно он задаёт ближайший срок повтора. Поскольку документ ещё не RFC, API не следует строить единственную совместимость на экспериментальных полях без явного versioned contract.

`429` относится к quota/rate конкретного caller. Если сервис временно режет весь входящий поток из-за давления на себя, `503` точнее сообщает о перегрузке capacity. Метрики также разделяют эти случаи.

## Пример или трассировка: distributed export abuse

Для tenant `acme` настроен bucket `B=100`, `r=20 tokens/s`. Обычный GET стоит 1 token, запуск export — 5. Одновременно действуют предел в два exports на account и десять на tenant.

1. После простоя bucket полон. В один момент с пяти accounts приходят 80 GET и 5 exports, суммарная стоимость 105.
2. Limiter атомарно пропускает 80 GET и первые 4 exports. Последний export видит 0 tokens и получает `429` с `Retry-After: 1`.
3. Через 250 ms восстановилось 5 tokens, но клиент следует целочисленной подсказке HTTP и повторяет не раньше секунды, добавив jitter. Повтор проходит, если tokens не потратил другой запрос.
4. Скрипт меняет IP и распределяет exports по двадцати accounts того же tenant. IP-limit уже не помогает, зато tenant bucket и предел outstanding exports сохраняют общую границу. Новые jobs не занимают worker pool.
5. Если множество независимых accounts остаётся ниже каждого бюджета, risk engine может связать одинаковые device/session признаки и последовательность чтений. Он требует step-up или отправляет поток на review; существующие authorization checks всё равно выполняются.
6. Отдельная месячная quota в один миллион resource units не меняет short-term burst policy. После её исчерпания API возвращает стабильную доменную ошибку до следующего периода или изменения плана.

Наблюдаемый результат: burst из 100 tokens допустим, средняя скорость после него ограничена refill. Смена IP не расширяет tenant budget, распределение по accounts не обходит предел доменного эффекта, а неоднозначное поведение обрабатывается отдельно от детерминированного limiter.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До RFC 6585 → апрель 2012 | Общего кода для rate limiting не было; использовались разные `4xx` | RFC 6585 определил `429 Too Many Requests` | Клиент может отличить своё превышение лимита от обычной ошибки запроса | RFC 6585 |
| Май 2026 | Реализации используют vendor-specific headers | Draft `-11` предлагает `RateLimit` и `RateLimit-Policy` | Можно проектировать совместимую подсказку, но нельзя выдавать draft за стабильный стандарт | `draft-ietf-httpapi-ratelimit-headers-11` |

## Trade-offs

Token bucket сохраняет burst tolerance, leaky bucket сглаживает поток. Первый лучше для интерактивного API с короткими пиками, второй — когда downstream важнее равномерность.

Локальный limiter отвечает без сетевого hop, глобальный точнее соблюдает общий контракт. Leased budget занимает середину: меньше coordination, но появляется bounded overshoot и задача перераспределения при отказе instance.

Rate limit по requests прост для клиента. Cost units лучше защищают реальную capacity, зато требуют объяснимой модели стоимости и осторожной эволюции, иначе одинаковый endpoint внезапно «дорожает».

Queue вместо `429` сглаживает короткий burst, но увеличивает latency и память. Очередь обязана иметь предел и учитывать [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline]], иначе запрос начнёт выполняться после того, как клиент перестал ждать.

Risk-based защита ловит low-and-slow и распределённое злоупотребление, которое не видно одному bucket. Цена — false positives, privacy cost, adversarial drift и необходимость объяснять блокировку. Детерминированные per-effect limits проще проверять и должны оставаться последним барьером там, где бизнес-инвариант можно выразить точно.

## Типичные ошибки

### Лимит настроен на каждую replica как глобальный

- **Неверное предположение:** `100 rps` на instance означает 100 rps на сервис.
- **Симптом:** после масштабирования суммарный вход кратно превышает capacity downstream.
- **Причина:** независимые buckets не координируются.
- **Исправление:** явно назвать scope, разделить глобальный бюджет или использовать shared/leased limiter.

### Ключом служит только IP

- **Неверное предположение:** один IP равен одному клиенту.
- **Симптом:** офис или мобильный NAT блокируется целиком, атакующий обходит лимит сменой адресов.
- **Причина:** transport identity не совпадает с tenant identity.
- **Исправление:** лимитировать authenticated principal и использовать IP как дополнительный abuse signal.

### Все запросы стоят один token

- **Неверное предположение:** request count пропорционален нагрузке.
- **Симптом:** несколько exports исчерпывают CPU/БД при формально низком rps.
- **Причина:** limiter не учитывает resource cost и concurrency.
- **Исправление:** разделить классы, ввести cost units и concurrent cap.

### Клиенты повторяют строго в момент reset

- **Неверное предположение:** единый `Retry-After` сам предотвращает перегрузку.
- **Симптом:** новый spike ровно на границе окна.
- **Причина:** cohort остаётся синхронной.
- **Исправление:** server hint, client-side jitter и [[40 Распределённые системы/Retry, exponential backoff и jitter|ограниченная retry policy]].

### Rate limit считают полной защитой от abuse

- **Неверное предположение:** атакующий обязан сохранять один IP, account и высокий rps.
- **Симптом:** credential stuffing, scraping или reservation abuse идёт ниже каждого локального порога.
- **Причина:** budget проверяет одну выбранную ось, а противник распределяет действия и использует валидный workflow.
- **Исправление:** слоить limits по identity/action/cost, ограничить доменный эффект, коррелировать сигналы и предусмотреть step-up/review с измеримым false-positive rate.

## Когда применять

Rate limiting нужен для fairness, защиты capacity и коммерческих policy. Сначала фиксируют identity, scope, unit и burst semantics. Quota добавляют, когда важно суммарное потребление за период; concurrency limit — когда ресурс удерживается во времени. Для login, recovery, account creation, scraping-sensitive reads и дефицитных бизнес-операций поверх них проектируют abuse policy и безопасный путь разблокировки.

Если цель меняется вместе с текущим CPU, queue delay или memory pressure, статического rate limit недостаточно. Это уже adaptive admission и load shedding.

## Источники

- [RFC 6585: Additional HTTP Status Codes](https://datatracker.ietf.org/doc/html/rfc6585) — IETF, RFC 6585, апрель 2012, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RateLimit header fields for HTTP](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers-11) — IETF HTTPAPI Working Group, Internet-Draft `-11`, май 2026, срок действия до 2026-11-24, проверено 2026-07-18.
- [Request throttling for the Amazon EC2 API](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html) — Amazon Web Services, официальная документация EC2 API, проверено 2026-07-18.
- [Local rate limit](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_filters/local_rate_limit_filter) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [NIST SP 800-63B-4: Authentication and Authenticator Management](https://pages.nist.gov/800-63-4/sp800-63b.html) — NIST, SP 800-63B-4, июль 2025, проверено 2026-07-18.
- [OWASP Automated Threats to Web Applications](https://owasp.org/www-project-automated-threats-to-web-applications/) — OWASP Foundation, vendor-neutral taxonomy OAT-001–OAT-021, проверено 2026-07-18.
- [Bot Management and Anti-Automation Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Bot_Management_and_Anti-Automation_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная редакция на 2026-07-18, проверено 2026-07-18.
