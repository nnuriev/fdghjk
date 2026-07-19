---
aliases:
  - Avito speedrun
  - Avito — 48-часовой маршрут
tags:
  - тип/маршрут
  - компания/авито
статус: проверено
---

# Avito — speedrun roadmap на 48 часов

## Назначение и границы

Этот маршрут помогает работающему Middle Go-разработчику за двое суток восстановить базу и подготовиться к более высокому грейду на Go-backend интервью Avito. Он не заменяет полный [[Авито/roadmap|Avito roadmap]] и не пересказывает решения: исходный маршрут хранит задачи, а здесь канонические знания vault расположены по приоритету и порядку повторения.

Приоритет опирается на сохранённый набор из [[Авито/Источники|источников Avito]], прямое присутствие темы в вопросах и задачах, переиспользование между алгоритмами, Go Platform, screening и System Design, а также на Senior+-сигнал ответа. Это стратегия подготовки, а не гарантия конкретного вопроса на интервью.

Behavioral-подготовка не входит в этот speedrun: в сохранённом наборе Avito она не представлена отдельной секцией. Задания без полного условия также не используются как материал для воспроизведения контракта.

## Как читать приоритеты

- **P0 — воспроизводить.** Ответ, код или архитектурный skeleton нужно восстановить без заметок.
- **P1 — применять.** Нужно объяснить механизм, вывести failure modes и trade-offs, затем перенести модель на новый сценарий.
- **P2 — объяснить.** Достаточно связного ответа на 60–90 секунд: назначение, ближайшая альтернатива и одно ограничение.
- **P3 — после дедлайна.** Не открывайте эти темы, пока в P0 или P1 остаются пробелы.

Тема готова, если без подсказки получается пройти цепочку:

`инвариант → механизм → ограничение ресурса → failure mode → альтернатива → способ проверки`

Для первичной диагностики используйте три состояния:

- **зелёное** — вся цепочка воспроизводится и выдерживает вопрос «что изменится, если…»;
- **жёлтое** — определение знакомо, но механизм, граница гарантии или trade-off теряются;
- **красное** — ответ не начинается без подсказки.

При ограниченном времени сначала переводите жёлтые темы в зелёные, затем закрывайте центральные красные. Узкая новая тема обычно даёт меньший результат, чем восстановление уже знакомой модели.

Списки ниже — карта результатов и fallback-ссылок, а не линейный reading list. Зелёную тему не перечитывайте; P1 рассматривайте как очередь после P0, а не как обязательство пройти каждую ссылку за двое суток.

## Карта знаний

### P0 — воспроизводить

#### Алгоритмическое рассуждение

Сначала восстановите [[10 Основы CS/Оценка временной и пространственной сложности|оценку сложности]] и [[10 Основы CS/Доказательство корректности алгоритма|доказательство через инвариант]]. Для прямых задач Avito нужны:

- [[10 Основы CS/Массивы, строки, хеш-таблицы и множества|массивы, строки, hash map и set]];
- [[10 Основы CS/Сортировка и бинарный поиск|сортировка и binary search]];
- [[10 Основы CS/Префиксные суммы и difference arrays|prefix reasoning]];
- [[10 Основы CS/Two pointers и sliding window|two pointers и sliding window]];
- [[10 Основы CS/Edge cases, невалидный ввод и overflow|edge cases, invalid input и overflow]].

Контрольная точка — обе задачи из [[Авито/roadmap#1. Рекомендованные алгоритмы|рекомендованного алгоритмического блока]]. Каждая должна решаться из пустого файла с формулировкой контракта, инварианта, сложности и тестов.

#### Go: семантика языка

Нужно причинно объяснять:

- [[60 Go/Zero values, семантика значений и копирование|value semantics и поверхностное копирование]];
- [[60 Go/Структуры, указатели и методы|указатели и изменение объекта]];
- [[60 Go/Функции, function values и замыкания|замыкания и loop variables]], включая [[Авито/Источники#Loop variables в Go|границу Go 1.22, проверенную 2026-07-18]];
- [[60 Go/Массивы и слайсы|slice header, backing array, len, cap и append]];
- [[60 Go/Map|контракт map]], отсутствие порядка и ограничения concurrent access;
- [[60 Go/Интерфейсы и неявная реализация|интерфейсы и method sets]];
- [[60 Go/Nil, type assertions и type switches в интерфейсах|typed nil, assertions и type switches]];
- [[60 Go/Обработка ошибок|ошибки, wrapping, errors.Is и errors.As]].

Отдельно проговорите ловушки исходного screening: lookup в [[60 Go/Map|map]] имеет ожидаемую, а не worst-case стоимость `O(1)`; у map нет slice-подобного контракта `cap`; [[60 Go/Context, deadlines и распространение отмены|context]] переносит deadline и cancellation, но не заменяет flow control.

#### Go: concurrency и lifecycle

Для любого concurrent-кода сначала называйте owner состояния и lifecycle goroutines, а затем точку синхронизации:

- [[60 Go/Goroutines и lifecycle|goroutine lifecycle]];
- [[60 Go/Буферизация, ownership и закрытие каналов|состояния каналов, ownership и close]];
- [[60 Go/select, cancellation и timeout|select, cancellation и timeout]];
- [[60 Go/Context, deadlines и распространение отмены|context, deadline и обязательный CancelFunc]];
- [[60 Go/Mutex, RWMutex и примитивы координации sync|Mutex, RWMutex, WaitGroup, Once и Cond]];
- [[60 Go/Пакет sync-atomic|sync-atomic]] и границы применимости атомиков;
- [[60 Go/Модель памяти Go и happens-before|happens-before и visibility]];
- [[60 Go/Data races, deadlocks и livelocks|data races, deadlocks и livelocks]];
- [[60 Go/Goroutine и channel leaks|goroutine и channel leaks]];
- [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|worker pool, fan-in/fan-out и bounded concurrency]].

#### Production Go и ограниченные ресурсы

Практический ответ должен связывать concurrency с реальными лимитами:

- [[60 Go/HTTP-клиент и Transport|HTTP Client и Transport]], reuse connections и lifecycle response body;
- [[60 Go/Тайм-ауты HTTP-сервера и клиента|тайм-ауты HTTP-сервера и клиента]];
- [[20 Бэкенд/Пулы соединений и keep-alive|connection pools и keep-alive]];
- [[10 Основы CS/Исчерпание ресурсов процесса|CPU, memory, FD и connection exhaustion]];
- [[Авито/Решения/Go-платформа/Прогноз погоды и cache|TTL-cache]]: freshness policy, concurrent ownership, warm-up, single-flight по ключу и bounded key cardinality; общий failure mode — [[70 Практические кейсы/Thundering herd|cache stampede и thundering herd]].

Контрольная точка — семь задач из [[Авито/roadmap#2. Backend Platform Go|Backend Platform Go]]. Для каждой проговорите contract, ownership/lifecycle, resource bound, cancellation, error policy и failure-path test.

#### SQL и реляционная база данных

Минимальное ядро screening:

- [[30 Данные/SQL - joins, aggregations, subqueries, CTE и window functions|joins, aggregations, WHERE, HAVING и GROUP BY]];
- [[30 Данные/Индексы и цена чтения и записи|индексы и их цена для reads/writes]];
- [[30 Данные/Планы выполнения SQL-запросов|execution plan, cardinality и выбор индекса]];
- [[30 Данные/Транзакции и ACID|граница транзакции и ACID]];
- [[30 Данные/Уровни изоляции транзакций|уровни изоляции и допустимые истории]];
- [[30 Данные/Блокировки, MVCC и deadlocks|locking, MVCC и deadlocks]].

#### ОС, сеть и путь запроса

Нужно уметь за несколько минут провести запрос через слои и на каждом назвать ресурс, timeout и наблюдаемый отказ:

- [[10 Основы CS/Процесс, поток и goroutine|process, thread и goroutine]];
- [[10 Основы CS/Файловые дескрипторы|file descriptors]] и их связь с sockets/connections;
- [[10 Основы CS/Блокирующий и неблокирующий ввод-вывод|blocking и non-blocking I/O]];
- [[10 Основы CS/Модель TCP-IP и путь пакета|путь пакета и запроса]];
- [[10 Основы CS/DNS resolution и caching|DNS]], [[10 Основы CS/TCP - handshake, надёжность и управление перегрузкой|TCP]], [[10 Основы CS/TLS handshake и проверка сертификатов|TLS]], [[10 Основы CS/HTTP-1.1|HTTP/1.1]];
- [[10 Основы CS/Тайм-ауты на сетевых уровнях|тайм-ауты на сетевых уровнях]].

#### System Design

Скелет ответа должен воспроизводиться до знакомства с конкретным кейсом:

1. [[50 Проектирование систем/Методика System Design интервью|уточнить задачу и вести интервью]];
2. собрать [[50 Проектирование систем/Функциональные и нефункциональные требования|functional и non-functional requirements]];
3. зафиксировать [[50 Проектирование систем/SLO в System Design|SLO]] и сделать [[50 Проектирование систем/Оценка нагрузки и ёмкости|оценку нагрузки и ёмкости]];
4. определить [[50 Проектирование систем/Проектирование API и модели данных|API и data model]];
5. нарисовать [[50 Проектирование систем/Архитектурная схема и критические потоки|архитектуру, read path и write path]];
6. обосновать [[50 Проектирование систем/Выбор хранилища, партиционирование и репликация в System Design|storage, partitioning и replication]];
7. разобрать [[50 Проектирование систем/Failure handling в System Design|failure handling]] и [[50 Проектирование систем/Observability в System Design|observability]].

Контрольная точка — четыре условия из [[Авито/roadmap#4. System design|System Design]]. Для каждого нужен skeleton за 10–12 минут; один случайный кейс нужно полностью прогнать за 45 минут.

### P1 — применять

#### Runtime и диагностика Go

Свяжите [[60 Go/Планировщик GMP|GMP]], [[60 Go/Netpoller|netpoller]], [[60 Go/Стеки и escape analysis|goroutine stacks и escape analysis]] и [[60 Go/Аллокации, GC и GC pressure|GC pressure]] с наблюдаемой latency и расходом ресурсов. Для диагностики различайте [[60 Go/Профилирование с pprof|pprof]], [[60 Go/Execution trace|execution trace]] и [[60 Go/Race detector|race detector]]: каждый инструмент отвечает на свой класс вопросов. В direct-screening tail также входят [[60 Go/Pointer и value receivers, method sets|pointer/value receivers]], [[60 Go/defer, panic и recover|defer/panic/recover]], [[60 Go/Тестирование и httptest|go test/httptest]] и [[60 Go/Table-driven tests в Go|table-driven tests]].

#### Неопределённый результат и безопасный повтор

Главная цепочка распределённого backend:

`partial failure → deadline → неизвестный результат → retry policy → idempotency/deduplication → durable async effect`

Опорные модели:

- [[40 Распределённые системы/Частичные отказы|частичные отказы]];
- [[20 Бэкенд/Дедлайны запросов и распространение отмены|end-to-end deadline и cancellation propagation]];
- [[40 Распределённые системы/Retry, exponential backoff и jitter|retry, exponential backoff и jitter]];
- [[20 Бэкенд/Идемпотентные и неидемпотентные операции|семантика повторного выполнения]] и [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|idempotency keys]];
- [[40 Распределённые системы/Idempotency и deduplication|deduplication в распределённой обработке]];
- [[40 Распределённые системы/At-most-once, at-least-once и effectively-once processing|delivery и processing guarantees]];
- [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|queues, streams, consumer groups и DLQ]];
- [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox и CDC]].

#### Перегрузка и устойчивость

Рассуждайте по цепочке `offered load → admitted load → очередь → saturation → tail latency → overload policy`:

- [[40 Распределённые системы/Backpressure и queue buildup|backpressure и queue buildup]];
- [[40 Распределённые системы/Load shedding|load shedding]];
- [[40 Распределённые системы/Circuit breaker|circuit breaker]];
- [[40 Распределённые системы/Retry storms и cascading failures|retry storms и cascading failures]];
- [[70 Практические кейсы/Throughput и saturation|throughput и saturation]];
- [[70 Практические кейсы/p50, p95 и p99 latency|p50, p95 и p99 latency]];
- [[70 Практические кейсы/Bulkheads и dependency isolation|bulkheads и dependency isolation]];
- [[70 Практические кейсы/Graceful degradation|graceful degradation]].

#### Данные, projections и согласованность

Сначала назовите canonical state, затем производные projections и допустимую свежесть:

- [[30 Данные/Моделирование данных и реляционная модель|data model и реляционные инварианты]];
- [[30 Данные/Репликация данных|replication]] и [[30 Данные/Партиционирование и шардирование|partitioning/sharding]];
- [[30 Данные/Hot partitions и hot keys|hot partitions и hot keys]];
- [[30 Данные/Search index|search index]], [[30 Данные/Object и blob storage|object/blob storage]], [[30 Данные/Distributed cache и KV store|distributed cache/KV]];
- [[30 Данные/Геопространственные индексы и поиск ближайших объектов|геопространственный candidate search]] и [[30 Данные/Data repair и reconciliation|reconciliation производных данных]];
- [[40 Распределённые системы/Ordering и causality|ordering и causality]];
- [[40 Распределённые системы/Strong, eventual, causal и session consistency|модели consistency]];
- [[40 Распределённые системы/Linearizability|linearizability]];
- [[40 Распределённые системы/Leases, distributed locks и fencing tokens|leases, distributed locks и fencing tokens]].

#### Reliability и безопасные изменения

Свяжите пользовательскую цель, наблюдение и управляющее действие:

- [[50 Проектирование систем/SLO в System Design|SLI/SLO/SLA]] и [[70 Практические кейсы/Error budgets|error budget]];
- [[70 Практические кейсы/Dashboards и actionable alerts|dashboards и actionable alerts]];
- [[70 Практические кейсы/Incident mitigation|incident mitigation]] и [[70 Практические кейсы/Root-cause analysis|root-cause analysis]];
- [[70 Практические кейсы/Canary, blue-green и rolling deployment|canary, blue-green и rolling deployment]];
- [[70 Практические кейсы/Rollback|rollback]] и [[50 Проектирование систем/Миграция и rollout без остановки|миграция без остановки]].

#### Low-Level Design

Для локального компонента проходите цепочку `domain invariant → public API → state transitions → ownership/concurrency → dependency seams → tests`:

- [[50 Проектирование систем/Domain model и инварианты|domain model и инварианты]];
- [[50 Проектирование систем/Public API компонента|обязательства public API]];
- [[50 Проектирование систем/State transitions и конечный автомат|state transitions]];
- [[50 Проектирование систем/Concurrency safety Go-компонента|concurrency safety]];
- [[50 Проектирование систем/Cohesion и coupling|cohesion/coupling]] и [[50 Проектирование систем/Dependency inversion|dependency inversion]];
- [[50 Проектирование систем/Testability Go-компонента|testability]] и [[50 Проектирование систем/Maintainability|maintainability]].

#### Security

Начните не с каталога атак, а с assets, identities и trust boundaries:

- [[20 Бэкенд/Моделирование угроз|threat modeling]];
- [[20 Бэкенд/Аутентификация и авторизация на уровне API|authentication и authorization]];
- [[20 Бэкенд/Least privilege|least privilege]];
- [[20 Бэкенд/Управление секретами|secret lifecycle и rotation]];
- [[20 Бэкенд/Rate limiting и quotas|rate limiting и quotas]].

### P2 — объяснить

На этом уровне не нужно воспроизводить детали реализации. Достаточно механизма, ближайшей альтернативы и одного существенного trade-off.

- **Storage и узкие DB-механизмы:** по [[30 Данные/Карта — Данные|карте данных]] — B-tree/B+tree, WAL, fsync/durability, LSM-tree, compaction, read/write amplification, database triggers и выбор между SQL, key-value, document, wide-column, search, time-series и blob storage.
- **Distributed theory:** по [[40 Распределённые системы/Карта — Распределённые системы|карте распределённых систем]] — CAP/PACELC, consensus, 2PC/Saga, multi-region и RPO/RTO.
- **Testing и infrastructure:** [[20 Бэкенд/Стратегия тестирования backend|risk-based test strategy]], mocks/fakes, fuzzing, load/stress testing и [[20 Бэкенд/Контейнеры, виртуальные машины и Kubernetes Pod|container, VM и Kubernetes Pod]].
- **OS/network screening tail:** по [[10 Основы CS/Карта — Основы CS|карте основ CS]] — stack/heap/virtual memory, select/poll/epoll/kqueue, UDP и signals/graceful termination.
- **Algorithm coverage:** задачи из [[Авито/roadmap#5. Остальные алгоритмы|остального алгоритмического набора]] группируются по hash map/two pointers, heap/selection, recursion/graph и parser/edge cases. Полный код нужен только для случайного представителя каждой группы.
- **System Design archetypes:** из [[50 Проектирование систем/Карта — Проектирование систем|карты High-Level System Design]] запоминайте не готовые схемы, а отличительный инвариант класса: ordering для chat, preferences/delivery для notifications, ledger для payments, rebuildable projection для search, lease/fencing для scheduler.

### P3 — после дедлайна

- [[Авито/roadmap#Задания без сохранённого условия|Задания без сохранённого условия]]: по названию нельзя надёжно восстановить контракт, API или expected output.
- [[Авито/roadmap#Вне выбранного scope|Материалы вне Go-backend scope]].
- [[10 Основы CS/BGP и IS-IS|BGP/IS-IS]], глубокие детали [[10 Основы CS/HTTP-2 и multiplexing|HTTP/2]], [[10 Основы CS/HTTP-3 и QUIC|HTTP/3/QUIC]] и certificate-path internals TLS.
- Механика Paxos/Raft, quorum algebra и алгоритмы LSM compaction глубже концептуального ответа P2.
- Полный каталог security-уязвимостей и каталог Strategy/Adapter/Factory/Decorator/Observer/State без конкретного кейса.
- Исторические версии и повторное чтение источников, кроме границ, реально меняющих ответ, например loop variables начиная с Go 1.22.

## Как работать с одной темой

1. **Pretest, 2–3 минуты.** До открытия заметки сформулируйте инвариант, механизм и главный failure mode.
2. **Чтение, 8–12 минут.** Откройте только `TL;DR`, ментальную модель, причинный механизм, пример, типичные ошибки и trade-offs.
3. **Закрытая книга, 90 секунд.** Объясните тему своими словами без текста перед глазами.
4. **Перенос, 3–5 минут.** Ответьте на вопрос «что изменится, если нагрузка, порядок, отказ или граница транзакции будут другими?».
5. **Журнал ошибок, одна строка.** Запишите `вопрос → неверное предположение → исправленное правило`.

В конце блока, вечером, утром второго дня и перед интервью повторяйте только ошибки, красные темы и неустойчивые жёлтые ответы. Узнавание текста не считается готовностью: ответ должен начинаться без подсказки.

## Speedrun на 48 часов

В таблицах указано чистое время фокусной работы. Между блоками используйте циклы примерно `75 минут работы / 15 минут перерыва`, отдельно заложите еду и прогулку.

### День 1 — база и реализация, 10 часов

| Время | Блок | Проверяемый результат |
| ---: | --- | --- |
| 45 мин | Диагностика P0 по разделам выше | Кластеры проверены короткими вопросами по 30–60 секунд и помечены зелёным, жёлтым или красным; чтение ещё не начинается |
| 90 мин | Go basics | Без заметок объясняются pointer rebinding, slice aliasing, map, typed nil и error wrapping |
| 150 мин | Concurrency и Go Platform | Семь кейсов Platform объясняются по contract/ownership/bound/cancellation/failure; два code skeleton написаны с нуля |
| 120 мин | Алгоритмы | Обе рекомендованные задачи решены под таймером; проговорены инвариант, тесты и сложность |
| 90 мин | SQL и DB | Для нового запроса выбран индекс; объяснены execution plan, MVCC, anomaly и deadlock |
| 75 мин | ОС и сети | За пять минут нарисован путь DNS→TCP→TLS→HTTP→handler→dependency с ресурсом и timeout на границах |
| 30 мин | Закрытый recall | Двадцать перемешанных вопросов; в журнал попадают только реальные ошибки |

После блока recall остановитесь. Первая ночь сна — не менее `7,5–8 часов`.

### День 2 — отказы, runtime и проектирование, 11 часов

| Время | Блок | Проверяемый результат |
| ---: | --- | --- |
| 45 мин | Утренний recall | P0 восстанавливается по памяти; новые материалы не открываются до проверки |
| 90 мин | Backend failure protocol | Разобран сценарий timeout с неизвестным результатом: deadline, retry policy, idempotency и commit boundary |
| 90 мин | Distributed и reliability | Разобраны dependency outage и queue backlog: saturation, backpressure, shedding, observability и containment |
| 75 мин | Runtime и debugging | Для CPU, memory, goroutine, race и scheduler проблем выбран правильный инструмент и ожидаемый сигнал |
| 105 мин | System Design foundation | Общий skeleton воспроизводится за 10–12 минут с requirements, estimates, API/data и critical paths |
| 120 мин | Четыре Avito System Design кейса | Четыре skeleton готовы; один случайный кейс полностью прогнан за 45 минут и разобран |
| 60 мин | LLD и security | Спроектирован bounded concurrent component с invariant/API/state/tests и обозначены trust boundaries |
| 75 мин | Смешанный mock | Алгоритм 25 мин, Go/debugging 20 мин, теория 10 мин, System Design outline 15 мин и краткий разбор ошибок 5 мин |

Вторая ночь сна — не менее `7,5–8 часов`. В последние 45 минут перед интервью повторяйте только журнал ошибок и P0-каркас; новый материал не открывайте.

## Критерии завершения

- В P0 нет темы, по которой ответ не начинается без подсказки.
- Обе рекомендованные алгоритмические задачи решаются из пустого файла не дольше 30 минут каждая, включая тесты и сложность.
- Все семь Go Platform кейсов объясняются через contract, ownership/lifecycle, resource bound, cancellation и failure paths; минимум два случайных skeleton пишутся с нуля.
- Индексы/MVCC, timeout/retry/idempotency и путь backend-запроса объясняются причинно, а не как набор определений.
- Четыре System Design кейса набрасываются за 10–12 минут; один полностью проходит 45-минутный mock с estimates, API/data, тремя failure modes и двумя trade-offs.
- В смешанном наборе из 40 вопросов есть не менее 32 зелёных ответов и ни одного красного ответа по P0. Набор фиксирован по областям: 8 алгоритмических, 12 Go/Platform, 8 SQL/ОС/сети, 8 backend/distributed/reliability и 4 System Design.

Если критерий P0 не выполнен, не расширяйте P2 и P3. Максимальный результат даёт исправление центральной ошибки, а не ещё одна пассивно прочитанная заметка.

## Навигация и основание

- [[Авито/roadmap|Полный Avito roadmap]] — задачи, screening и исходный порядок секций.
- [[Авито/Источники|Источники Avito]] — происхождение, дубли, неоднозначности и версионные границы материалов.
- [[01 Маршруты/Backend — от основ к архитектуре|Backend — от основ к архитектуре]] — полный маршрут vault без 48-часового ограничения.
