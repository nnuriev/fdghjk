---
aliases:
  - Boundary и failure-path testing
  - Boundary testing
  - Failure-path testing
  - Negative testing
tags:
  - область/бэкенд
  - тема/тестирование
  - тема/надёжность
статус: черновик
---

# Тестирование границ и failure paths

## TL;DR

Boundary test выбирает значения непосредственно по обе стороны от каждого разрыва поведения: minimum, maximum, deadline, capacity, state transition или version boundary. Failure-path test вводит отказ в конкретной фазе операции и проверяет не только returned error, но и durable state, внешние effects, освобождение ресурсов, retry semantics и observability.

Главный oracle звучит не «метод вернул ошибку», а «при outcome X система сохранила invariants Y». Для операции записи особенно различаются отказ до side effect, подтверждённый rollback и потеря ответа после успешного commit: одинаковый timeout на client не доказывает одинаковое состояние server.

## Ментальная модель

Happy path проверяет одну линию через state machine. Boundary и failure-path testing проверяют места, где линия ветвится:

```text
input partition -> boundary decision -> state transition
                                      -> dependency call
                                      -> commit
                                      -> response/ack
```

У теста два независимых измерения:

1. **Где находится условие?** Input range, time, capacity, protocol version, object state, concurrency threshold.
2. **В какой фазе произошёл отказ?** До effect, во время effect с известным rollback, после commit до response или во время recovery.

Для каждой точки задают observable oracle:

```text
response category
+ durable records
+ emitted messages/calls
+ resource lifecycle
+ security and telemetry constraints
```

Точное сообщение exception обычно не главный invariant. Стабильный code, operation identity, отсутствие partial state и допустимость retry важнее формулировки для человека.

## Как устроено

### Граница — это смена правила, а не просто большое число

Для целого inclusive range `[L, U]` базовый набор — `L-1`, `L`, `L+1`, nominal value, `U-1`, `U`, `U+1`. Если `L-1` или `U+1` не представимы целевым типом, malformed value нужно подать на более раннюю boundary как bytes/string; иначе test сам переполнит значение до вызова system under test.

Числовой шаблон дополняют semantic partitions:

- absent, explicit `null`, empty, whitespace-only и zero — разные состояния, если контракт их различает;
- empty collection, one item, maximum count и maximum + 1;
- exact byte limit с multibyte encoding, nesting depth и decompressed size;
- deadline `T-ε`, ровно `T` и `T+ε`;
- pool/queue capacity `N-1`, `N`, `N+1`;
- version до/на/после compatibility cutoff;
- state transition из каждого разрешённого и запрещённого predecessor state.

Правила parsing и rejection задаёт [[20 Бэкенд/Защитная обработка невалидного ввода|защитная обработка невалидного ввода]], а byte/resource thresholds — [[20 Бэкенд/Ограничения размера входных данных и исчерпание ресурсов|отдельный resource budget]]. Boundary test не изобретает эти числа: он доказывает реализацию уже объявленного контракта.

### Значение ровно на time/concurrency boundary требует явного контракта

Если timer expiry и result становятся ready одновременно, scheduler order может быть не определён. Тест не должен случайно закреплять один interleaving. Возможны два корректных design:

- implementation задаёт precedence через явный synchronization protocol, и test проверяет его;
- contract допускает несколько результатов, а test принимает set outcomes, но для каждого требует общий safety invariant — например, не более одного commit и обязательное завершение goroutines.

Для таких сценариев `sleep` не создаёт доказуемый порядок. Controlled clock и causal synchronization разобраны в [[60 Go/Детерминированное тестирование concurrent code|детерминированном тестировании concurrent code]]. Data race при этом остаётся отдельным классом дефекта, который ищет [[60 Go/Race detector|race detector]].

### Failure matrix строится по фазам side effect

Для write operation полезно перечислить phases, а не только названия dependencies:

| Фаза injection | Что может знать caller | Основной invariant |
| --- | --- | --- |
| До validation/authorization | effect не начинался | нет business writes/calls |
| После validation, до dependency call | command допустима, effect не начинался | нет partial state, resources released |
| Dependency вернула definite failure до commit | операция не зафиксирована | rollback/compensation выполнен |
| Commit мог пройти, но response потерян | outcome неизвестен caller | retry не дублирует logical operation |
| После commit сломалась доставка event/ack | durable state уже есть | recovery повторяет propagation; downstream допускает transport duplicate, но не повторный logical effect |
| Во время cleanup/recovery | исходная ошибка уже произошла | cleanup bounded, original cause не потеряна |

Injection seam должен уметь вернуть не только generic `error`, но и meaningful modes: timeout, cancellation, unavailable, malformed response, partial read/write, constraint conflict, deadlock victim, lost acknowledgement. Иначе несколько разных протокольных состояний схлопываются в одну искусственную ветку.

### Oracle охватывает состояние после ответа

Для каждого case стоит явно проверять:

- какие rows/objects созданы, изменены или отсутствуют;
- сколько внешних calls/messages было и с каким operation/event ID;
- завершены или освобождены ли transaction, response body и file; остановлены ли ненужные timers, завершились ли goroutines;
- дошёл ли cancellation и соблюдён ли общий time budget;
- сохранились ли stable error category и retry hint;
- не появились ли secrets, unbounded labels и log storm;
- что произойдёт при повторе того же запроса и при recovery worker.

Проверка только mock call count хрупка: она может доказать внутреннюю последовательность и пропустить неверный durable outcome. Проверка только БД тоже неполна, если handler оставил goroutine или отправил duplicate command.

### Комбинаторный взрыв сокращают по причине риска

Не нужно перемножать каждое граничное значение на каждый failure point. Сначала partition inputs по одинаковому expected behavior, затем выбирают representatives у разрывов. Cross-field combinations покрывают domain invariants и наиболее опасные interactions; общие алгебраические свойства переносят в [[20 Бэкенд/Property-based testing|property-based testing]], а неизвестные parser states исследует [[60 Go/Fuzzing|fuzz testing]].

Любой найденный production/fuzz counterexample сохраняют как именованный deterministic regression case. Seed полезен для воспроизведения, но название должно объяснять нарушенный invariant.

## Пример или трассировка

Пусть transfer API принимает сумму от 1 до 10 000 cents, а ledger row и outbox row записывает атомарно в одной database transaction. Повтор с тем же idempotency key должен обозначать ту же logical operation.

Первый слой — boundary table:

| Amount | Ожидаемый outcome | Durable state |
| ---: | --- | --- |
| 0 | validation error | transfer = 0, outbox = 0 |
| 1 | success | transfer = 1, outbox = 1 |
| 9 999 | success | transfer = 1, outbox = 1 |
| 10 000 | success | transfer = 1, outbox = 1 |
| 10 001 | validation error | transfer = 0, outbox = 0 |

Второй слой — иллюстративная failure trace, без запуска кода:

1. Request с `amount=10_000` и key `k-42` проходит validation.
2. Test double БД фиксирует transaction, но transport теряет response до client.
3. Client наблюдает timeout. Это unknown outcome, а не доказанный rollback.
4. Client повторяет ту же command с key `k-42`.
5. Server находит сохранённый operation identity и возвращает исходный result, не создавая второй transfer/outbox row.
6. Assertions после recovery: ровно один logical transfer, один durable outbox event с тем же event ID, transaction resources закрыты; error/timeout logs не содержат payload secrets.

Если тот же timeout injected до transaction, expected durable state — ноль rows. Одинаковый client symptom проверяет две разные server branches. Семантика retry и unknown outcome подробнее раскрыта в [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|ключах идемпотентности]] и [[20 Бэкенд/Идемпотентные и неидемпотентные операции|различии идемпотентных операций]].

## Trade-offs

| Подход | Что доказывает хорошо | Чего не доказывает |
| --- | --- | --- |
| Unit test со scripted fake | точную фазу отказа, cleanup и реакцию конкретной ветки | реальные wire/driver semantics |
| Integration test с настоящей dependency | constraints, transaction и protocol behavior | редкие failure points без управляемого injector |
| End-to-end test | user-visible contract и wiring | локализацию причины и все комбинации |
| Property/fuzz test | широкий input space и воспроизводимые counterexamples; часть инструментов умеет их уменьшать | production recovery без полноценного oracle |

Scripted fake лучше generic mock, когда failure имеет state: «commit принят, response потерян» нельзя честно выразить одним `return error`. Но fake способен солгать о реальном driver. Поэтому критичные branches повторяют на ближайшем реальном уровне, а wire compatibility закрепляют [[20 Бэкенд/Contract tests|contract tests]].

Слишком точные assertions по тексту error, SQL call order или числу внутренних helper calls делают refactoring breaking change для тестов. Слишком широкие assertions вроде `err != nil` пропускают утрату данных. Граница проходит по observable contract и safety invariants.

## Типичные ошибки

- **«Достаточно minimum и maximum» → off-by-one остаётся в production → не проверены значения сразу за границей → добавляют below/at/above и следят, чтобы test representation само не overflow.**
- **«Вернулся timeout — запись не прошла» → retry создаёт duplicate → response мог потеряться после commit → моделируют unknown outcome и проверяют idempotency на durable state.**
- **«Mock вернул error, failure path покрыт» → real driver оставляет transaction или response body открытым → fake не моделирует lifecycle → добавляют cleanup assertions и integration case с реальной dependency.**
- **«At deadline всегда побеждает timeout» → test flaky на другом scheduler → precedence не задан contract/happens-before → задают protocol или принимают допустимый set outcomes с общим safety invariant.**
- **«Переберём декартово произведение всего» → suite медленный, а важная interaction всё равно потеряна в шуме → cases не связаны с risk model → partitions, pairwise/risk-based combinations и properties разделяют ответственность.**
- **«Проверили returned error» → остаётся partial write, leak или secret в log → oracle ограничен return value → проверяют durable state, external effects, resources и telemetry.**

## Когда применять

Boundary testing обязательно там, где поведение меняется дискретно: limits, pagination, numeric conversion, deadlines, queue/pool capacity, version negotiation, state machines и authorization scopes. Failure-path testing особенно важно для multi-step writes, network calls, transactions, queue acknowledgement, retries, cancellation и cleanup.

Для чистой функции достаточно table/property tests. Для операции с реальными side effects нужен layered набор: быстрые deterministic unit cases на каждую фазу, integration cases на protocol/constraint boundaries и небольшой end-to-end набор на user-visible recovery. Нагрузочные thresholds и разрушение производительности проверяются отдельно в [[70 Практические кейсы/Load и stress testing|load и stress testing]]: функциональный `N+1` case не заменяет длительный capacity experiment.

## Источники

- [CWE-20: Improper Input Validation](https://cwe.mitre.org/data/definitions/20.html) — MITRE, CWE 4.20, проверено 2026-07-18.
- [ISO/IEC/IEEE 29119-4:2021: Software testing — Test techniques](https://www.iso.org/standard/79430.html) — ISO/IEC/IEEE, Edition 2, проверено 2026-07-18.
- [Secure Software Development Framework](https://doi.org/10.6028/NIST.SP.800-218) — NIST, SP 800-218 Version 1.1, проверено 2026-07-18.
- [Go Fuzzing](https://go.dev/doc/security/fuzz/) — The Go Project, документация Go 1.26.5, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, проверено 2026-07-18.
- [RFC 9457: Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html) — IETF, RFC 9457, проверено 2026-07-18.
