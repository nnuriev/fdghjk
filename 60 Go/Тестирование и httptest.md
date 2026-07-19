---
aliases: []
tags:
  - область/go
статус: проверено
---

# Тестирование и httptest

## TL;DR

Go test — исполняемая спецификация observable contract. Table-driven tests разделяют сценарии и общий механизм проверки; subtests дают адресуемые имена и selective run; `httptest` позволяет проверить `http.Handler` без реального socket либо поднять локальный сервер для полного client/transport path.

Выбирайте самый узкий seam, который доказывает тезис: прямой вызов `ServeMux`/handler через `ResponseRecorder` проверяет routing, status, headers и redirect response без socket. `httptest.Server` нужен, когда важны client redirect-following, TLS, transport, connection или wire semantics.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: unit semantics переносима; integration timing и network stack зависят от платформы.
- Пакеты: `testing`, `net/http/httptest`, `net/http`.
- Вне scope: mocks framework, race detector и benchmarks.

## Ментальная модель

Тест состоит из arrangement, одного наблюдаемого действия и assertions над публичным эффектом. Хороший тест локализует нарушение контракта, а не повторяет implementation.

`testing.T` — владелец lifecycle конкретного test/subtest: failure state, logs, deadline, temp directory и cleanup. Resource должен регистрироваться через `t.Cleanup` там, где создаётся, чтобы ownership сохранялся при `Fatal` и раннем return.

## Как устроено

`go test` компилирует package вместе с `*_test.go` в отдельный test binary и запускает функции `TestXxx(*testing.T)`. `t.Run` создаёт subtest; имя входит в path для `-run`. Table удобно хранить как slice, когда cases имеют порядок или повторяющиеся имена, и как map, когда дополнительная вариативность порядка помогает выявить скрытое shared state.

`t.Parallel` приостанавливает subtest до завершения последовательной части parent и затем допускает конкурентный запуск в пределах `-parallel`. Parallel test не должен менять process-wide environment через `t.Setenv` и обязан изолировать mutable fixtures.

`httptest.NewRequest` создаёт server-side request для handler. `ResponseRecorder` реализует `ResponseWriter` и сохраняет status, headers и body; `Result` формирует `*http.Response`. Он не воспроизводит все свойства реального соединения, streaming flush и protocol negotiation.

`httptest.NewServer` действительно слушает loopback и предоставляет настроенный URL/client. Он нужен не для самого routing, а для механизмов реального client/server path: следования redirects, TLS, transport и connection behavior. Он медленнее и требует закрытия; `t.Cleanup(server.Close)` фиксирует ownership.

## Код

```go
package handler

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func createUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	fmt.Fprintf(w, "{\"id\":%q}\n", id)
}

func TestCreateUser(t *testing.T) {
	tests := []struct {
		name   string
		id     string
		status int
		body   string
	}{
		{name: "valid", id: "42", status: http.StatusCreated, body: "{\"id\":\"42\"}\n"},
		{name: "missing", status: http.StatusBadRequest, body: "missing id\n"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/users", nil)
			req.SetPathValue("id", tc.id)
			rec := httptest.NewRecorder()

			createUser(rec, req)

			if rec.Code != tc.status {
				t.Fatalf("status: got %d, want %d", rec.Code, tc.status)
			}
			if got := rec.Body.String(); got != tc.body {
				t.Fatalf("body: got %q, want %q", got, tc.body)
			}
		})
	}
}
```

## Ожидаемый результат

Команда `go test` завершается с exit code 0. Доказанные значения:

```text
valid:   status=201 body={"id":"42"}\n
missing: status=400 body=missing id\n
```

Строка `ok package duration` содержит недетерминированное время и поэтому не входит в ожидаемый контракт. Официальный Go Playground на Go 1.26.5 выполнил `TestCreateUser`: обе subtests `valid` и `missing` завершились `PASS`, проверено 2026-07-15.

## Эволюция и версии

| Версия | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Go 1.26 | `Server.Client()` маршрутизировал только URL самого test server | Client также направляет `example.com` и его subdomains в test server | Redirect chains на эти hosts можно тестировать без подмены DNS и custom transport | [Go 1.26 Release Notes](https://go.dev/doc/go1.26#net/http/httptest) |

## Trade-offs

- `ResponseRecorder` даёт быстрый unit test [[60 Go/HTTP-сервер на net-http|HTTP handler]] и точные assertions. `httptest.Server` выигрывает, когда важны redirects, [[60 Go/HTTP-клиент и Transport|client transport]], TLS или реальные boundaries чтения body.
- Table-driven test уменьшает дублирование, но чрезмерно универсальная таблица скрывает intent. Если cases требуют разных control flows и assertions, отдельные tests яснее; неизвестные варианты input space ищет [[60 Go/Fuzzing|fuzzing]].
- Проверка exact body ловит contract drift, но хрупка к незначимому порядку JSON fields. Для семантического JSON-контракта декодируйте body в typed value; exact bytes оставляйте, когда canonical representation сама часть контракта.

## Типичные ошибки

- Предположение: любой `ResponseRecorder.Code` до вызова handler равен 0. Симптом: тест с `httptest.NewRecorder()` проверяет неверную precondition. Причина: constructor сразу устанавливает `Code=200`; только вручную созданный zero-value `ResponseRecorder{}` хранит 0, а его `Result().StatusCode` нормализуется до 200. Исправление: различать constructor и zero value и проверять observable response после handler.
- Предположение: parallel subtests безопасно делят fixture. Симптом: flaky failures или [[60 Go/Race detector|data race]]. Причина: конкурентная mutation общего state. Исправление: создавать fixture внутри subtest или синхронизировать явно и регулярно запускать `go test -race`.
- Предположение: mock каждого dependency повышает изоляцию. Симптом: тест проходит при несовместимом реальном protocol. Причина: проверена копия ожиданий, а не boundary. Исправление: сочетать unit seam с небольшим integration test наиболее рискованного взаимодействия.
- Предположение: сравнение только status достаточно. Симптом: неверные headers/body проходят. Причина: контракт проверен частично. Исправление: assert минимальный полный набор observable invariants.

## Когда применять

Для чистой бизнес-функции используйте обычный table test. Для handler сначала используйте `NewRequest` и `ResponseRecorder`; добавляйте `NewServer` только для механизмов, которых recorder не моделирует. Не ограничивайтесь happy path: если риск включает освобождение ресурсов/cancellation, проверяйте это в failure scenario.

## Источники

- [Документация пакета testing](https://pkg.go.dev/testing@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Документация пакета net/http/httptest](https://pkg.go.dev/net/http/httptest@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.26 Release Notes — net/http/httptest](https://go.dev/doc/go1.26#net/http/httptest) — The Go Project, Go 1.26, проверено 2026-07-15.
- [Исходный код httptest.NewRecorder](https://github.com/golang/go/blob/go1.26.5/src/net/http/httptest/recorder.go#L50-L56) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/httptest/recorder.go`, проверено 2026-07-15.
- [Исходный код httptest.Server.Client](https://github.com/golang/go/blob/go1.26.5/src/net/http/httptest/server.go#L327-L335) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/httptest/server.go`, проверено 2026-07-15.
- [Исходный код httptest.NewRequest](https://github.com/golang/go/blob/go1.26.5/src/net/http/httptest/httptest.go#L19-L72) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/httptest/httptest.go`, функции `NewRequest` и `NewRequestWithContext`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
