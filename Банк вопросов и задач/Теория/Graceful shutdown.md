---
aliases:
  - "Теоретический вопрос: Graceful shutdown"
tags:
  - область/go
  - тип/вопрос
статус: проверено
---

# Graceful shutdown

## Вопрос

Объясните тему «Graceful shutdown» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Graceful shutdown — протокол смены ownership: перестать принимать новую работу, сообщить долгоживущим компонентам об отмене, дождаться уже принятой работы в ограниченный budget и только затем завершить процесс.

`http.Server.Shutdown` закрывает listeners, закрывает idle connections и ждёт, пока active connections станут idle. Он не ждёт hijacked connections, включая WebSocket, и не заменяет координацию фоновых workers.

Полный разбор: [[60 Go/Graceful shutdown|Graceful shutdown]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/04 Context и модель памяти#Graceful shutdown|Graceful shutdown]] — дополнительный вопрос о разнице `Shutdown` и `Close` HTTP server.
- [[CurseHunter/6593/03 Каналы, время и паттерны#Graceful shutdown|Graceful shutdown]] — вопрос об admission stop, cancellation, drain и deadline.
- «Pattern подходит для health checks, batch enrichment, fan-out и параллельной проверки endpoints. Перед production-запуском фиксируют global/per-host concurrency, deadline, response size, retry policy и partial-result contract. Настройки и ownership transport подробнее разобраны в заметке об HTTP client, а его закрытие при lifecycle сервиса — в заметке о graceful shutdown.» — [[Авито/Решения/Go-платформа/Параллельный запрос URL#Когда применять выводы|Авито/Решения/Go-платформа/Параллельный запрос URL, раздел «Когда применять выводы»]].

## Источники

- [Документация Server.Shutdown](https://pkg.go.dev/net/http@go1.26.5#Server.Shutdown) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Исходный код Server.Shutdown](https://github.com/golang/go/blob/go1.26.5/src/net/http/server.go#L3150-L3215) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/server.go`, символ `Server.Shutdown`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Документация пакета os/signal](https://pkg.go.dev/os/signal@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.16 Release Notes: signal.NotifyContext](https://go.dev/doc/go1.16) — The Go Project, Go 1.16, проверено 2026-07-15.
- [Go 1.26 Release Notes: os/signal](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
