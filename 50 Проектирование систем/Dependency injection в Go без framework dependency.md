---
aliases:
  - Dependency injection в Go
  - Manual dependency injection Go
  - DI без фреймворка
tags:
  - область/проектирование-систем
  - область/go
  - тема/зависимости
статус: черновик
---

# Dependency injection в Go без framework dependency

## TL;DR

Dependency injection (DI) означает, что компонент получает collaborators извне, а не создаёт их внутри и не ищет в global registry. В Go базовый вариант прост: обязательные dependencies передаются в constructor, сохраняются в unexported fields, а `main` или другой composition root вручную собирает concrete object graph и владеет cleanup.

DI не тождественен dependency inversion principle (DIP). DI отвечает на вопрос «кто передал object», DIP — куда направлена compile-time dependency. Маленький interface или function type объявляют у потребителя, если ему действительно нужна способность; producer обычно возвращает concrete type.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- GOOS и GOARCH: не влияют.
- Компоненты: constructors, adapters, package boundaries, process startup и tests.
- Вне scope: runtime plugin discovery и генерация wiring-кода.

## Ментальная модель

Object graph строится снаружи внутрь:

```text
main -> infrastructure adapters -> application service -> domain policy
```

Стрелка показывает создание и передачу instance. Source dependency при этом может смотреть обратно к контракту consumer: package application объявляет нужный `PriceSource`, а package adapter предоставляет concrete type, который удовлетворяет контракту неявно. Это продолжает правила [[60 Go/Пакеты, модули и направление зависимостей|направления package dependencies]].

Composition root знает concrete implementations, configuration, lifecycle и порядок shutdown. Domain component знает только входной contract. Внутри business method не должно быть `sql.Open`, чтения environment, обращения к singleton container или скрытой регистрации через `init`.

## Как устроено

Для одной операции достаточно named function type. Несколько связанных операций оформляют маленьким [[60 Go/Интерфейсы и неявная реализация|consumer-owned interface]]. Required dependencies передают отдельными constructor arguments; optional policy можно выразить config value или option, когда опциональность реальна.

Constructor устанавливает structural invariants: required dependencies присутствуют, limits допустимы, immutable config скопирован. Он не должен запускать неостановимую goroutine или выполнять долгий network call без context. Если adapter требует `Close`, composition root хранит concrete adapter и закрывает его в порядке, обратном созданию.

`Checkout` не имеет пригодного zero value: `Checkout{}` содержит nil `lookup`, и вызов `Quote` завершится panic. Public contract требует создавать компонент только через успешно завершившийся `NewCheckout` и использовать возвращённый `*Checkout`; прямой struct literal и `new(Checkout)` не поддерживаются.

Error semantics тоже входят в dependency contract. Adapter переводит storage-specific outcome в стабильный application sentinel, service отдельно возвращает validation error, а wrapping через `%w` добавляет контекст без потери identity. Caller проверяет такие ошибки через [[60 Go/Обработка ошибок|`errors.Is`]], поэтому замена concrete storage не меняет branching logic.

Dependency lifetime тоже часть дизайна:

- process-scoped client/pool обычно создаётся один раз и разделяется;
- request-scoped values приходят parameters/context, а не сохраняются в singleton;
- mutable dependency обязана документировать concurrency contract;
- test fake живёт не дольше test и не протекает в global state.

## Код

```go
package main

import (
	"context"
	"errors"
	"fmt"
)

type LookupPrice func(context.Context, string) (int64, error)

var (
	ErrInvalidSKU = errors.New("invalid sku")
	ErrNotFound   = errors.New("not found")
)

type Checkout struct {
	lookup LookupPrice
}

func NewCheckout(lookup LookupPrice) (*Checkout, error) {
	if lookup == nil {
		return nil, errors.New("price lookup is required")
	}
	return &Checkout{lookup: lookup}, nil
}

func (c *Checkout) Quote(ctx context.Context, sku string) (int64, error) {
	if sku == "" {
		return 0, ErrInvalidSKU
	}
	price, err := c.lookup(ctx, sku)
	if err != nil {
		return 0, fmt.Errorf("quote %q: %w", sku, err)
	}
	return price, nil
}

type Catalog map[string]int64

func (c Catalog) Price(_ context.Context, sku string) (int64, error) {
	price, ok := c[sku]
	if !ok { return 0, ErrNotFound }
	return price, nil
}

func main() {
	catalog := Catalog{"book": 700}
	checkout, err := NewCheckout(catalog.Price)
	if err != nil { panic(err) }
	price, err := checkout.Quote(context.Background(), "book")
	if err != nil { panic(err) }
	fmt.Println(price)
}
```

## Ожидаемый результат

Composition root использует `*Checkout` из успешно завершившегося `NewCheckout` и выбирает `Catalog.Price`; zero value `Checkout` не входит в API. Программа должна напечатать `700`. `Quote(ctx, "")` возвращает `ErrInvalidSKU`, поэтому `errors.Is(err, ErrInvalidSKU)` истинно. Для отсутствующего SKU adapter возвращает `ErrNotFound`; `Quote` добавляет контекст через `%w`, и `errors.Is(err, ErrNotFound)` остаётся истинно. В test тот же constructor принимает closure, которая возвращает нужную цену или ошибку, без container и package globals.

Код не выполнен: локальная toolchain Go недоступна. До запуска на Go 1.26.5 статус остаётся `черновик`.

## Trade-offs

- Ручной wiring прозрачен, проверяется compiler и легко ищется. Большой graph добавляет boilerplate; его можно вынести в несколько constructor-функций по bounded context, не вводя service locator.
- Function type минимален для одной операции. Interface лучше выражает связный protocol, но добавление метода ломает implementers; публичные interfaces требуют compatibility discipline.
- Constructor injection делает required graph явным. Setter injection разрешает наполовину собранный object и нужен редко, например для осознанного lifecycle transition.
- Functional options сохраняют совместимость при росте optional config, но скрывают required parameters и допускают конфликтующие options. Не используйте их автоматически.

## Типичные ошибки

- **Неверное предположение:** DI требует container. **Симптом:** runtime lookup, строковые keys и поздние ошибки сборки. **Причина:** object graph скрыт. **Исправление:** explicit constructors и wiring в composition root.
- **Неверное предположение:** component сам откроет database «для удобства». **Симптом:** tests требуют environment, connection lifecycle потерян. **Причина:** создание dependency смешано с использованием. **Исправление:** открыть adapter снаружи и передать готовый collaborator.
- **Неверное предположение:** producer обязан экспортировать interface своей реализации. **Симптом:** interface повторяет весь concrete API. **Причина:** контракт создан до consumer need. **Исправление:** producer возвращает concrete type, consumer объявляет узкую способность.
- **Неверное предположение:** global registry уменьшает coupling. **Симптом:** порядок tests влияет на результат, dependency не видна в signature. **Причина:** coupling стал скрытым. **Исправление:** parameter/field и локальная fixture по [[50 Проектирование систем/Testability Go-компонента|правилам testability]].
- **Неверное предположение:** `if dep == nil` поймает любой typed nil в interface. **Симптом:** constructor принимает non-nil interface с nil pointer. **Причина:** interface хранит dynamic type и value. **Исправление:** не передавать typed nil; для однооперационного contract функция даёт однозначную nil-проверку.

## Когда применять

Ручной DI подходит почти любому статическому Go service graph. Начните с concrete types и constructors; вводите interface/function seam там, где consumer реально должен заменить effect, разорвать compile-time dependency или поддержать несколько implementations. Генератор wiring оправдан при большом стабильном graph, но generated code должен оставаться обычным compile-time Go, а не runtime service locator.

## Источники

- [Compile-time Dependency Injection With Go Cloud's Wire](https://go.dev/blog/wire) — The Go Project, официальная статья, 2018-10-09, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, проверено 2026-07-18.
- [Keeping Your Modules Compatible](https://go.dev/blog/module-compatibility) — The Go Project, официальная статья о совместимости Go modules и interfaces, проверено 2026-07-18.
- [Package net/http: Client and RoundTripper](https://pkg.go.dev/net/http@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, пример explicit dependency через `Client.Transport`, проверено 2026-07-18.
- [Package errors](https://pkg.go.dev/errors@go1.26.5) — The Go Project, `errors.Is`, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package fmt: Errorf](https://pkg.go.dev/fmt@go1.26.5#Errorf) — The Go Project, wrapping через `%w`, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
