---
aliases: []
tags:
  - область/go
статус: проверено
---

# Тайм-ауты HTTP-сервера и клиента

## TL;DR

HTTP timeout — не одно число, а набор ограничений разных фаз: чтение headers/body, ожидание response headers, запись ответа, idle connection и полный budget операции. Самый ранний deadline завершает локальное ожидание; он не доказывает, что удалённая сторона уже прекратила работу.

Практическое правило: задавайте внешний end-to-end budget через `context.Context`, а transport/server timeout используйте как защитные границы конкретных фаз и ресурсов. Нулевые значения большинства timeout означают отсутствие ограничения.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: API одинаков; точность таймеров и сетевые ошибки зависят от ОС.
- Пакеты: `net/http`, `context`, `net/url`, `time`.
- Вне scope: подбор чисел под конкретный SLO и retry/backoff policy.

## Ментальная модель

Deadline — абсолютная граница, budget — оставшееся до неё время. Операция проходит несколько фаз, и на неё одновременно могут действовать request context, `Client.Timeout`, transport phase timeout и kernel deadline. Срабатывает самая ранняя из активных границ.

Timeout освобождает ожидание и, если нижний слой поддерживает cancellation, помогает освободить ресурсы. Но distributed side effect мог уже начаться. Поэтому retry после timeout безопасен только при идемпотентности или дедупликации.

## Как устроено

На сервере `ReadHeaderTimeout` ограничивает чтение headers и защищает от медленного клиента до handler. `ReadTimeout` охватывает чтение всего request, включая body, но плохо учитывает разные допустимые скорости upload. `WriteTimeout` ограничивает запись response, `IdleTimeout` — ожидание следующего request на keep-alive connection. Для handler-level work нужен `r.Context` и собственный budget.

На клиенте `Client.Timeout` охватывает connection setup, redirects и чтение response body; timer продолжает действовать после возврата `Do`, пока читается body. Поля `Transport` дают более узкие пределы: `TLSHandshakeTimeout`, `ResponseHeaderTimeout`, `ExpectContinueTimeout`, `IdleConnTimeout`; dial ограничивает `net.Dialer.Timeout`.

`NewRequestWithContext` связывает запрос с вызывающей операцией. Если request deadline короче `Client.Timeout`, срабатывает он; если client timeout короче — client отменяет underlying request так же, как при завершении context. Ошибка `Client.Do` оборачивается в `*url.Error`; `Timeout()` классифицирует timeout, а `errors.Is(err, context.DeadlineExceeded)` сохраняет причинную проверку.

Нельзя просто делить SLO поровну между hop. Downstream должен получить меньше оставшегося budget, чем upstream, чтобы вызывающая сторона успела классифицировать ответ и освободить ресурсы. Защитный timeout также должен учитывать нормальную latency distribution, иначе он сам создаёт retry storm.

## Код

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

type waitingTransport struct{}

func (waitingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	<-r.Context().Done()
	return nil, r.Context().Err()
}

func main() {
	client := &http.Client{
		Transport: waitingTransport{},
		Timeout:   time.Second,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		"https://service.test/slow",
		nil,
	)

	_, err := client.Do(req)
	var urlErr *url.Error
	fmt.Println("deadline exceeded:", errors.Is(err, context.DeadlineExceeded))
	fmt.Println("timeout error:", errors.As(err, &urlErr) && urlErr.Timeout())
}
```

## Ожидаемый результат

```text
deadline exceeded: true
timeout error: true
```

Request budget в 10 ms короче общего client timeout в одну секунду, поэтому отменяется context. `Client` возвращает `*url.Error`, сохраняя timeout-классификацию и `context.DeadlineExceeded` в error chain. Пример выполнен в официальном Go Playground на Go 1.26.5; обе проверки дали `true`, проверено 2026-07-15.

## Trade-offs

- `Client.Timeout` — простая страховка полного lifecycle. [[60 Go/Context, deadlines и распространение отмены|Request context]] лучше передаёт budget вызывающей операции и причину cancellation; в production обычно нужны оба уровня.
- Короткий `ResponseHeaderTimeout` быстро освобождает slot при медленном upstream, но ошибочно обрывает допустимые долгие запросы. Отдельный client/transport по классу операции яснее одного компромиссного значения.
- `ReadTimeout` ограничивает медленный body целиком, но не выражает допустимую скорость и размер upload. Для крупных загрузок нужны body limit, per-request policy и при необходимости обновляемые deadlines.

## Типичные ошибки

- Предположение: нулевой timeout означает разумный default. Симптом: зависшие sockets и исчерпание goroutines или connection slots. Причина: ноль обычно отключает ограничение. Исправление: явно задать server, client и operation budgets.
- Предположение: любой timeout можно безопасно повторить. Симптом: двойное списание или дубликат команды. Причина: timeout не сообщает, был ли side effect применён удалённо. Исправление: идемпотентный контракт, idempotency key или reconciliation.
- Предположение: `WriteTimeout` ограничивает всю работу handler. Симптом: CPU/DB-работа продолжает занимать ресурс. Причина: поле ограничивает сетевую запись, а не произвольное вычисление. Исправление: следить за `r.Context` и передавать его в зависимости.
- Предположение: достаточно сравнить строку ошибки. Симптом: wrapper или платформа ломает классификацию. Причина: ошибки оборачиваются. Исправление: использовать `errors.Is`, `errors.As` и `net.Error.Timeout`/`url.Error.Timeout`.

## Когда применять

В [[60 Go/HTTP-сервер на net-http|публичном HTTP-сервере]] всегда задавайте как минимум защиту чтения headers и idle connections; остальные пределы выбирайте по типу body и streaming. Для [[60 Go/HTTP-клиент и Transport|HTTP-клиента]] создавайте policy-specific client, передавайте request context и резервируйте часть budget вызывающей стороне.

Связывайте timeout с admission control и [[60 Go/Backpressure|backpressure]]: timeout без bounded concurrency только быстрее создаёт новые попытки.

## Источники

- [Документация net/http: Server, Client и Transport timeout](https://pkg.go.dev/net/http@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Исходный код HTTP-клиента](https://github.com/golang/go/blob/go1.26.5/src/net/http/client.go) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/client.go`, тип `Client` и функция `send`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
