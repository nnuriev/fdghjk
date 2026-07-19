---
aliases:
  - Integration testing
  - Интеграционные тесты
tags:
  - область/бэкенд
  - тема/тестирование
статус: проверено
---

# Integration tests

## TL;DR

Integration test проверяет, что два или несколько реальных компонентов согласны о протоколе и вместе сохраняют нужный инвариант. Его цель — поймать дефекты на стыке: SQL и migration, serialization и wire format, driver и server, producer и broker, lifecycle и readiness.

Это не «unit test, который случайно медленный». Перед тестом явно объявляют границу: например, repository + настоящий PostgreSQL 18, а всё остальное заменено. Реальной должна быть именно та dependency, чья semantics составляет проверяемый риск.

## Область применимости

Основной пример относится к PostgreSQL 18, актуальной поддерживаемой major version на 2026-07-18. Те же принципы применимы к message brokers, object storage, HTTP adapters и нескольким in-process modules.

Полный пользовательский путь через все процессы остаётся задачей [[20 Бэкенд/End-to-end tests|end-to-end test]], а совместимость независимо выпускаемых consumer/provider — [[20 Бэкенд/Contract tests|contract test]]. Integration suite может использовать HTTP или несколько процессов, но его scope остаётся выбранным стыком.

## Ментальная модель

У каждого adapter есть два контракта:

```text
внутренний port <-> adapter <-> внешний protocol/implementation
```

Unit test с mock способен проверить левую сторону: какие намерения application передала adapter. Integration test нужен для правой: действительно ли query, transaction, encoding и error mapping работают с поддерживаемой реализацией dependency.

Поэтому тест должен содержать хотя бы один production connector с обеих сторон стыка. Если application заменена test script, а database — in-memory map, интеграция, ради которой создан test, не выполняется.

## Как устроено

### Выбрать один рискованный стык

Полезные scopes:

- repository implementation + реальная версия СУБД + production migrations;
- producer/consumer serializer + реальный broker;
- HTTP client adapter + controllable real HTTP server;
- service startup + configuration + dependency readiness;
- два bounded components, если риск находится в их composition.

Остальные зависимости можно заменить, чтобы отказ локализовался. Например, при проверке SQL repository внешний payment provider не нужен.

### Воспроизводимо собрать среду

Среда входит в fixture:

- image или binary dependency фиксируют до поддерживаемой major/minor policy;
- применяют те же migrations и настройки, что идут в release;
- readiness проверяют protocol-level probe, а не факт запуска process/container;
- каждому test или worker выделяют отдельную database/schema/namespace;
- cleanup принадлежит тому же lifecycle, который создал ресурс;
- версии application, schema и dependency сохраняют в test artifact.

Container полезен как механизм доставки, но не является доказательством готовности. Docker Compose отдельно различает running и ready: зависимый service можно ждать по `service_healthy`, если healthcheck действительно проверяет способность принимать нужные операции.

### Управлять test data и transaction boundaries

Test должен сам создать минимальное начальное состояние и не зависеть от порядка запуска. Transaction rollback после case быстро очищает данные, но искажает поведение, если SUT открывает другое соединение, должен увидеть commit, запускает worker или проверяет crash/retry. Тогда используют уникальный namespace и явное удаление либо пересоздают ephemeral database.

Параллельные tests не должны делить natural keys, queue topics или process globals. Случайный suffix уменьшает collision, но seed и вычисленное имя сохраняют в failure log.

### Проверять observable contract стыка

Repository integration test вызывает production port и проверяет typed result/error, а при необходимости — минимальный внешний postcondition в базе. HTTP adapter проверяет method, headers, body и mapping status. Broker test подтверждает serialization, key/partition metadata и redelivery semantics, но не пытается одним сценарием доказать весь workflow.

Failure paths важнее простого connect:

- constraint violation и mapping в domain error;
- rollback при ошибке между несколькими writes;
- cancellation/deadline во время I/O;
- reconnect после закрытого соединения;
- duplicate delivery и повторная команда;
- несовместимая migration или configuration.

Связь pool lifecycle с реальной dependency раскрыта в [[20 Бэкенд/Пулы соединений и keep-alive|заметке о connection pools]]: mock connection не воспроизводит saturation, stale sockets и server-side limits.

## Пример или трассировка

Требование: email пользователя уникален без учёта регистра. Production migration PostgreSQL 18 создаёт `UNIQUE INDEX users_email_lower_uq ON users (lower(email))`; repository переводит соответствующее нарушение uniqueness в `ErrEmailTaken`.

Тестовая трассировка:

1. Запускается чистый PostgreSQL 18 и применяются production migrations.
2. `CreateUser("Alice@Example.com")` через production repository возвращает `u-1`.
3. `CreateUser("alice@example.com")` через новый application transaction возвращает `ErrEmailTaken`.
4. Query через repository находит ровно одного пользователя; его исходный email не был перезаписан.

Наблюдаемый результат доказывает сразу четыре звена: migration реально создала expression index, PostgreSQL применил case-insensitive uniqueness к `lower(email)`, driver передал конкретную ошибку, repository правильно сопоставил её domain contract.

Fake map с ключом `strings.ToLower(email)` может проверить application rule, но не обнаружит пропущенную migration, неверное имя constraint, несовместимый SQL или ошибку driver mapping. Именно поэтому этот сценарий принадлежит integration boundary.

## Trade-offs

Настоящая dependency даёт максимальную fidelity выбранного protocol, но увеличивает startup time и требования к CI. Emulator или fake быстрее и позволяет легко инъецировать ошибки, зато может расходиться в transaction, collation, consistency и limits. Для риска совместимости production adapter обычно нужен хотя бы небольшой suite на реальной поддерживаемой версии.

Один environment на suite дешевле, чем process на каждый case, но требует строгой изоляции данных и не проверяет clean startup. Fresh environment на test надёжнее, но может сделать feedback неприемлемо долгим. Частый компромисс — один versioned service на test worker, отдельная database/schema на case и отдельный startup/migration test.

Прямой query к базе упрощает диагностику, но привязывает test к representation. Он оправдан, когда предмет проверки — сам repository/schema contract. На service integration boundary лучше наблюдать через публичный port, оставляя внутренние таблицы свободными для refactoring.

## Типичные ошибки

- **Неверное предположение:** container status `running` означает readiness. **Симптом:** первые cases случайно получают connection refused или migration race. **Причина:** process запущен, но protocol ещё не готов. **Исправление:** bounded protocol-level readiness probe и сохранение startup logs.
- **Неверное предположение:** in-memory database эквивалентна production СУБД. **Симптом:** suite проходит, production расходится по SQL, isolation или constraints. **Причина:** заменена именно проверяемая semantics. **Исправление:** использовать поддерживаемую реальную engine/version для adapter contract.
- **Неверное предположение:** rollback всегда обеспечивает isolation. **Симптом:** worker не видит данные или test не воспроизводит post-commit defect. **Причина:** внешняя transaction test harness скрыла настоящий commit boundary. **Исправление:** отдельный namespace и явный lifecycle для multi-connection scenarios.
- **Неверное предположение:** shared staging делает test реалистичнее. **Симптом:** failures зависят от чужих данных и параллельных deploy. **Причина:** fixture не принадлежит test. **Исправление:** ephemeral или namespaced environment с фиксированными версиями; staging оставить для отдельного release signal.
- **Неверное предположение:** один успешный CRUD доказывает repository. **Симптом:** duplicate, rollback или cancellation ломает production. **Причина:** проверен только happy path. **Исправление:** выбрать cases по constraints, transaction boundaries и error mapping.
- **Неверное предположение:** integration suite должен включать все dependencies. **Симптом:** медленная диагностика и каскадные падения. **Причина:** scope превратился в неявный E2E. **Исправление:** оставить реальным рискованный стык, остальные границы контролировать и документировать.

## Когда применять

Integration tests нужны вокруг каждого production adapter, migration и protocol feature, чьё поведение нельзя вывести из типов языка. Особенно ценны cases, где fake легко выглядит правдоподобно, но реальная система имеет constraints, transactions, encoding, delivery или lifecycle semantics.

Suite запускают при изменении adapter, schema, driver и dependency version. Compatibility matrix по всем поддерживаемым версиям оправдана, если продукт действительно обещает их поддержку; случайная проверка одной «latest» версии такого обещания не доказывает.

## Источники

- [Testing for Reliability](https://sre.google/sre-book/testing-reliability/) — Google, Site Reliability Engineering, глава 17, integration tests и стоимость уровней, проверено 2026-07-18.
- [Hermetic Servers](https://testing.googleblog.com/2012/10/hermetic-servers.html) — Google Testing Blog, 2012, isolated real servers и controlled dependencies, проверено 2026-07-18.
- [Getting Started](https://testcontainers.com/getting-started/) — Testcontainers, официальная документация о lifecycle, isolation и wait strategies, проверено 2026-07-18.
- [Control startup and shutdown order in Compose](https://docs.docker.com/compose/how-tos/startup-order/) — Docker, Compose Specification и документация о `running` и `service_healthy`, проверено 2026-07-18.
- [Indexes on Expressions](https://www.postgresql.org/docs/18/indexes-expressional.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [Unique Indexes](https://www.postgresql.org/docs/18/indexes-unique.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
