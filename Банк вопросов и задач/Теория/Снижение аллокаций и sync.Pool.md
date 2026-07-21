---
aliases:
  - "Теоретический вопрос: Снижение аллокаций и sync.Pool"
tags:
  - область/go
  - тема/runtime
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Снижение аллокаций и sync.Pool

## Вопрос

Объясните тему «Снижение аллокаций и sync.Pool» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Снижать allocations выгодно там, где профиль показывает значимый [[60 Go/Аллокации, GC и GC pressure|allocation churn и GC pressure]]. Сначала помогают [[60 Go/Стеки и escape analysis|stack allocation]], предварительная capacity, streaming и более короткий lifetime. `sync.Pool` — GC-aware cache временных объектов, а не хранилище и не bounded object pool: runtime может удалить любой item без уведомления, а `Get` вправе игнорировать ранее выполненный `Put`. Корректный код обязан работать и при постоянных misses, сбрасывать состояние перед reuse и ограничивать retained capacity крупных buffers.

Полный разбор: [[60 Go/Снижение аллокаций и sync.Pool|Снижение аллокаций и sync.Pool]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/02 Примитивы синхронизации#`sync.Pool`|`sync.Pool`]] — вопрос о temporary reuse, GC eviction и запрещённых storage assumptions.
- «Базовые варианты — stack allocation, preallocation/capacity hint, reuse destination, grouping lifetime в arena и pool ограниченного размера. Их границы подробно разобраны в escape analysis и снижении аллокаций через reuse и `sync.Pool`. `sync.Pool` — GC-aware optional cache: runtime вправе удалить entries, размер не ограничен business policy, а object перед `Put` надо привести к безопасному состоянию. Это не allocator с гарантированным lifetime и не bounded cache.» — [[CurseHunter/6817/Бланк вопросов и заданий#6. Прямой вопрос: почему хвалятся `allocation-free`|CurseHunter/6817, раздел «6. Прямой вопрос: почему хвалятся `allocation-free`»]].

## Источники

- [Package sync: Pool](https://pkg.go.dev/sync@go1.26.5#Pool) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [sync/pool.go: per-P locals, victim cache и Get/Put](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/sync/pool.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/mgc.go: pool cleanup at GC](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mgc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Package bytes: Buffer.Reset and Buffer.Cap](https://pkg.go.dev/bytes@go1.26.5#Buffer) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
