---
aliases:
  - "Теоретический вопрос: Доступ к базам данных из Go"
tags:
  - область/go
  - тема/базы-данных
  - тип/вопрос
статус: черновик
---

# Доступ к базам данных из Go

## Вопрос

Как устроен доступ к базе через `database/sql` и где выбирать direct SQL, query builder, code generation или ORM?

## Короткий ориентир

`*sql.DB` представляет concurrency-safe pool, а не одну connection. Корректный repository передаёт context, закрывает `Rows`, проверяет `Rows.Err`, удерживает transaction operations на одной connection и выбирает SQL abstraction по контролю запросов, типизации и стоимости поддержки.

Полные разборы:

- [[60 Go/Пакет database-sql и пулы соединений|Пакет database/sql и пулы соединений]]

## Варианты follow-up

- Почему `*sql.DB` не является одной connection?
- Зачем закрывать `Rows` и проверять `Rows.Err()`?
- Когда query builder полезнее ORM, а explicit SQL проще обоих вариантов?

## Варианты формулировки и происхождение

- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Доступ к базам из Go — `00:20:43–00:25:15`|APM Group, доступ к БД]].

## Источники

- [Документация пакета database/sql](https://pkg.go.dev/database/sql@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Managing connections](https://go.dev/doc/database/manage-connections) — Go project, документация `database/sql`, проверено 2026-07-15.
- [Исходный код пула database/sql](https://github.com/golang/go/blob/go1.26.5/src/database/sql/sql.go#L507-L586) — репозиторий golang/go, tag go1.26.5, файл `src/database/sql/sql.go`, тип `DB`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
- [pgx](https://github.com/jackc/pgx/tree/v5.7.6) — репозиторий `jackc/pgx`, tag `v5.7.6`, PostgreSQL driver/toolkit и stdlib compatibility; проверено `2026-07-18`.
- [sqlx](https://github.com/jmoiron/sqlx/tree/v1.4.0) — репозиторий `jmoiron/sqlx`, tag `v1.4.0`, extensions к `database/sql`; проверено `2026-07-18`.
