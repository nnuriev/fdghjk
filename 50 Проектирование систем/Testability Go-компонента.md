---
aliases:
  - Testability Go component
  - Тестопригодность Go-компонента
tags:
  - область/проектирование-систем
  - область/go
  - тема/тестирование
статус: черновик
---

# Testability Go-компонента

## TL;DR

Testability означает, что observable contract компонента можно проверить быстро, детерминированно и через небольшой setup. Для этого чистые вычисления отделяют от времени, случайности, I/O и goroutines; необходимые effects передают явно; lifecycle имеет точку ожидания; ошибки и результаты видны через API.

Тестируемость не равна числу interfaces или mocks. Mock каждого внутреннего вызова закрепляет текущую реализацию и может пропустить несовместимость с реальным protocol. Хороший seam совпадает с границей эффекта или ответственности, а тест проверяет результат и инвариант.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- GOOS и GOARCH: unit tests переносимы; network, filesystem, timing и race coverage зависят от среды.
- Пакеты: `testing`, `testing/synctest`, `net/http/httptest`; обычные functions и consumer-owned interfaces как seams.
- Вне scope: выбор внешнего mock framework и end-to-end test infrastructure.

## Ментальная модель

У компонента три вида входов:

1. явные arguments;
2. dependencies, которые читают или меняют внешний мир;
3. скрытая nondeterminism: clock, random, scheduling, process globals.

Тест легко строится, когда все три вида контролируемы, а наблюдения идут через публичный API. Поэтому `time.Now()` глубоко в domain method хуже injected `Now`, package-level repository хуже constructor dependency, fire-and-forget goroutine хуже метода с определённым completion/shutdown contract.

Самый узкий тест, доказывающий риск, предпочтительнее широкого. Чистая функция проверяется table test. HTTP handler сначала проверяют через [[60 Go/Тестирование и httptest|`httptest.ResponseRecorder`]], а реальный test server добавляют только для transport/TLS semantics. Parser дополняют [[60 Go/Fuzzing|fuzzing]], concurrent contract проверяют `-race` и контролируемыми interleavings.

## Как устроено

Практичные design rules:

- constructor получает обязательные dependencies и не оставляет наполовину собранный object;
- однооперационную dependency удобно выразить named function type, многометодную способность — маленьким interface у consumer;
- pure policy принимает values и возвращает values; adapter отдельно делает I/O;
- context приходит от caller, а компонент не создаёт бесконечный background context для request work;
- goroutine имеет owner, stop signal и способ дождаться завершения по [[60 Go/Goroutines и lifecycle|явному lifecycle]];
- clock, random source и retry sleeper контролируются тестом, если их поведение влияет на контракт;
- mutable fixture принадлежит одному test либо синхронизируется; parallel tests не делят process globals.

`Service` не имеет пригодного zero value: у `Service{}` обе function-dependencies равны nil, поэтому вызов `Notify` завершится panic. Public contract требует создавать компонент только через успешно завершившийся `New` и использовать возвращённый `*Service`; прямой struct literal и `new(Service)` не поддерживаются.

`testing/synctest` в Go 1.26.5 полезен для кода с goroutines и временем: test выполняется в изолированной bubble, а virtual time продвигается, когда goroutines внутри durably blocked. Это убирает реальные sleeps, но не заменяет хороший lifecycle и assertions.

## Код

```go
// service.go
package reminder

import (
	"context"
	"errors"
	"time"
)

var ErrInvalidUser = errors.New("invalid user")

type Message struct {
	UserID string
	SentAt time.Time
}

type Now func() time.Time
type Send func(context.Context, Message) error

type Service struct {
	now  Now
	send Send
}

func New(now Now, send Send) (*Service, error) {
	if now == nil || send == nil {
		return nil, errors.New("missing dependency")
	}
	return &Service{now: now, send: send}, nil
}

func (s *Service) Notify(ctx context.Context, userID string) error {
	if userID == "" {
		return ErrInvalidUser
	}
	return s.send(ctx, Message{UserID: userID, SentAt: s.now()})
}
```

```go
// service_test.go
package reminder

import (
	"context"
	"testing"
	"time"
)

func TestNotify(t *testing.T) {
	fixed := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	var got Message
	svc, err := New(
		func() time.Time { return fixed },
		func(_ context.Context, m Message) error { got = m; return nil },
	)
	if err != nil { t.Fatal(err) }
	if err := svc.Notify(context.Background(), "u-42"); err != nil { t.Fatal(err) }
	if got.UserID != "u-42" || !got.SentAt.Equal(fixed) {
		t.Fatalf("message: got %+v", got)
	}
}
```

## Ожидаемый результат

`TestNotify` использует `*Service` из успешно завершившегося `New`, не читает wall clock, не отправляет реальное сообщение и проверяет полный observable effect: identity получателя и timestamp. Zero value `Service` не входит в поддерживаемый API. Отдельные cases должны подтвердить, что пустой `userID` возвращает `ErrInvalidUser` и не вызывает `send`, а ошибка sender возвращается caller без подмены.

Код не выполнен: локальная toolchain Go недоступна. До запуска `go test` на Go 1.26.5 заметка остаётся `черновик`.

## Trade-offs

- Function dependency компактна для одной операции и легко заменяется closure. Interface лучше группирует связный protocol из нескольких методов, но расширяет mock surface.
- Fake быстрее и детерминированнее real dependency, но может расходиться с её semantics. Один integration/contract test на рискованной boundary остаётся нужен.
- Export внутренних полей облегчает setup, зато ломает encapsulation. Test helper или constructor с предметными параметрами сохраняет production invariants.
- Deterministic scheduler test даёт воспроизводимость, но не покрывает все interleavings. Его дополняют stress, `go test -race` и проверка invariants.

## Типичные ошибки

- **Неверное предположение:** testability требует interface для каждого struct. **Симптом:** десятки mocks повторяют implementation. **Причина:** abstractions поставлены не на effect boundaries. **Исправление:** concrete values внутри, узкие seams у потребителя.
- **Неверное предположение:** `time.Sleep` синхронизирует тест. **Симптом:** flaky либо медленный suite. **Причина:** время не доказывает наступление события. **Исправление:** явный signal, completion API или `testing/synctest`.
- **Неверное предположение:** private state нужно сравнить целиком. **Симптом:** безопасный refactoring ломает tests. **Причина:** проверяется representation. **Исправление:** assert публичный outcome и предметные invariants.
- **Неверное предположение:** unit mock доказывает интеграцию. **Симптом:** production adapter не соблюдает protocol, хотя tests зелёные. **Причина:** mock воспроизвёл ожидание автора. **Исправление:** contract test с реальным adapter на минимальной boundary.

## Когда применять

Testability проектируют вместе с public API: перечисляют observable outcomes, sources of nondeterminism, external effects и lifecycle. Для существующего кода сначала добавляют characterization test текущего поведения, затем вводят один seam вокруг самой дорогой или нестабильной зависимости. Dependency injection как способ сборки подробно разобран в [[50 Проектирование систем/Dependency injection в Go без framework dependency|отдельной заметке]].

## Источники

- [Package testing](https://pkg.go.dev/testing@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package testing/synctest](https://pkg.go.dev/testing/synctest@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Testing Time (and other asynchronicities)](https://go.dev/blog/testing-time) — The Go Project, официальная статья о `testing/synctest`, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, проверено 2026-07-18.
- [Data Race Detector](https://go.dev/doc/articles/race_detector) — The Go Project, документация toolchain Go 1.26.5, проверено 2026-07-18.
