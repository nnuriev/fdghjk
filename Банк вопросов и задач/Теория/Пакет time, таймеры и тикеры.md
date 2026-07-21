---
aliases:
  - "Теоретический вопрос: Пакет time, таймеры и тикеры"
tags:
  - область/go
  - тип/вопрос
статус: проверено
---

# Пакет time, таймеры и тикеры

## Вопрос

Объясните тему «Пакет time, таймеры и тикеры» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`Timer` моделирует одно будущее событие, `Ticker` посылает периодические сигналы, а deadline через `Context` отменяет операцию по времени. Ни один из них не гарантирует точный момент выполнения: событие становится доступно не раньше заданного duration, а scheduler может доставить его позже.

В Go 1.26 при module directive `go 1.23` или новее channel-based timers используют синхронные каналы: после возврата `Stop` или `Reset` нельзя получить stale value от прежней конфигурации. `Stop` не закрывает канал.

Полный разбор: [[60 Go/Пакет time, таймеры и тикеры|Пакет time, таймеры и тикеры]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/03 Каналы, время и паттерны#Время: Timer и Ticker|Время: Timer и Ticker]] — исходный версионный блок о timer semantics.
- [[CurseHunter/6593/03 Каналы, время и паттерны#Практические вопросы|Практические вопросы о Timer и Ticker]] — варианты `Stop`, `Reset`, GC и `AfterFunc` на границе Go 1.23.
- «Прогноз погоды и cache — TTL-cache, concurrent access, warm-up и stampede. База: in-memory cache, thundering herd, time.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Этот pattern подходит для локального read-through cache над медленной dependency, когда одинаковые ключи часто приходят одновременно. Перед внедрением нужно зафиксировать freshness, stale/error policy, key cardinality, refresh timeout, overload response и ownership background work. TTL и время жизни timers подробнее разобраны в заметке о time, а конкурентный доступ к встроенному map — в заметке о map.» — [[Авито/Решения/Go-платформа/Прогноз погоды и cache#Когда применять выводы|Авито/Решения/Go-платформа/Прогноз погоды и cache, раздел «Когда применять выводы»]].

## Источники

- [Документация пакета time](https://pkg.go.dev/time@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.23 Release Notes: Timer changes](https://go.dev/doc/go1.23#timer-changes) — Go project, Go 1.23, проверено 2026-07-15.
- [Исходный код Timer](https://github.com/golang/go/blob/go1.26.5/src/time/sleep.go#L113-L181) — репозиторий golang/go, tag go1.26.5, файл `src/time/sleep.go`, методы `Timer.Stop`, `NewTimer`, `Timer.Reset`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
