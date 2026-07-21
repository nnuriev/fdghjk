---
aliases:
  - "Теоретический вопрос: HTTP-клиент и Transport"
tags:
  - область/go
  - тип/вопрос
статус: проверено
---

# HTTP-клиент и Transport

## Вопрос

Объясните тему «HTTP-клиент и Transport» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`http.Client` задаёт политику запроса: redirects, cookies и общий timeout. Его `RoundTripper`, обычно `*http.Transport`, выполняет один обмен и владеет состоянием соединений, proxy, TLS и HTTP/2.

И `Client`, и `Transport` рассчитаны на повторное конкурентное использование. Pool принадлежит transport: новые clients с `Transport == nil` разделяют `http.DefaultTransport`, а новый transport на каждый запрос создаёт отдельный pool. Непрочитанный или незакрытый `Response.Body` может помешать повторному использованию HTTP/1.x-соединения.

Полный разбор: [[60 Go/HTTP-клиент и Transport|HTTP-клиент и Transport]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Cancellation и HTTP resource lifecycle связывают Context, deadlines и распространение отмены, HTTP-клиент и Transport и Тайм-ауты HTTP-клиента.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Для повторного использования HTTP/1.x keep-alive соединения документация `net/http` требует прочитать body до EOF и закрыть его. Если тело потенциально велико и содержимое не нужно, безусловное полное чтение тоже опасно; выбирают ограниченный контракт ответа, timeout/limit либо осознанно отказываются от reuse. Эти связи подробно разобраны в заметке об HTTP client и Transport.» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Resource lifetime|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Resource lifetime»]].
- «| HTTP + cancellation | HTTP-клиент и Transport и Goroutine и channel leaks | Прямое совпадение resource lifetime и cancellation | Ozon поэтапно доводит задачу до channel lifecycle и остановки после двух success |» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Сопоставление с материалами репозитория|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Сопоставление с материалами репозитория»]].
- «Параллельный запрос URL — `http.Client`, `httptest`, отмена sibling requests и ограничение числа in-flight запросов. База: HTTP client/Transport, HTTP timeouts, cancellation, connection pools.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Pattern подходит для health checks, batch enrichment, fan-out и параллельной проверки endpoints. Перед production-запуском фиксируют global/per-host concurrency, deadline, response size, retry policy и partial-result contract. Настройки и ownership transport подробнее разобраны в заметке об HTTP client, а его закрытие при lifecycle сервиса — в заметке о graceful shutdown.» — [[Авито/Решения/Go-платформа/Параллельный запрос URL#Когда применять выводы|Авито/Решения/Go-платформа/Параллельный запрос URL, раздел «Когда применять выводы»]].

- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Три HTTP-запроса и `errgroup` — `00:13:39–00:25:46`|Три HTTP-запроса и `errgroup` — `00:13:39–00:25:46`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [Документация пакета net/http: Client и Transport](https://pkg.go.dev/net/http@go1.26.5#Client) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.24 Release Notes — net/http](https://go.dev/doc/go1.24#net/http) — The Go Project, Go 1.24, проверено 2026-07-15.
- [Go 1.26 Release Notes — net/http](https://go.dev/doc/go1.26#net/http) — The Go Project, Go 1.26, проверено 2026-07-15.
- [Исходный код Client.Do](https://github.com/golang/go/blob/go1.26.5/src/net/http/client.go#L173-L193) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/client.go`, проверено 2026-07-15.
- [Исходный код Transport.NewClientConn](https://github.com/golang/go/blob/go1.26.5/src/net/http/clientconn.go#L93-L113) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/clientconn.go`, проверено 2026-07-15.
- [Исходный код Transport](https://github.com/golang/go/blob/go1.26.5/src/net/http/transport.go#L97-L335) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/transport.go`, тип `Transport`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
