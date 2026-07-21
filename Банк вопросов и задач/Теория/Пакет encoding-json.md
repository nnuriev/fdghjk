---
aliases:
  - "Теоретический вопрос: Пакет encoding-json"
tags:
  - область/go
  - тип/вопрос
статус: проверено
---

# Пакет encoding-json

## Вопрос

Объясните тему «Пакет encoding-json» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`encoding/json` связывает динамическую JSON-модель с конкретной Go-моделью через reflection, exported fields и struct tags. За permissive defaults приходится платить: unknown fields обычно игнорируются, числа в `any` становятся `float64`, совпадение field names допускает регистронезависимый fallback.

На строгой API-границе декодируйте в отдельный transport struct, включайте `DisallowUnknownFields`, сохраняйте числа через `UseNumber`, ограничивайте размер body и проверяйте, что после первого JSON value нет trailing data.

Полный разбор: [[60 Go/Пакет encoding-json|Пакет encoding-json]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Интервью-применение: `encoding/json` кодирует nil slice как `null`, а non-nil empty slice как `[]`. Если внешний API различает эти значения, выбор становится частью wire contract; подробнее это связано с контрактом encoding/json.» — [[CurseHunter/6754/Бланк вопросов и заданий#Задача 2. Почему обработчик не замечает отсутствие операций?|CurseHunter/6754, раздел «Задача 2. Почему обработчик не замечает отсутствие операций?»]].

## Источники

- [Документация пакета encoding/json](https://pkg.go.dev/encoding/json@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.24 Release Notes — encoding/json](https://go.dev/doc/go1.24#encoding/json) — The Go Project, Go 1.24, проверено 2026-07-15.
- [Go 1.25 Release Notes — experimental encoding/json/v2](https://go.dev/doc/go1.25#new-experimental-encoding-json-v2-package) — The Go Project, Go 1.25; применимо к Go 1.26.5, проверено 2026-07-15.
- [Исходный код omitzero](https://github.com/golang/go/blob/go1.26.5/src/encoding/json/encode.go#L107-L145) — репозиторий golang/go, tag go1.26.5, файл `src/encoding/json/encode.go`, проверено 2026-07-15.
- [Документация experimental json/v2 в исходном коде](https://github.com/golang/go/blob/go1.26.5/src/encoding/json/v2/doc.go#L5-L15) — репозиторий golang/go, tag go1.26.5, файл `src/encoding/json/v2/doc.go`, проверено 2026-07-15.
- [Исходный код io.LimitReader](https://github.com/golang/go/blob/go1.26.5/src/io/io.go#L458-L480) — репозиторий golang/go, tag go1.26.5, файл `src/io/io.go`, проверено 2026-07-15.
- [Исходный код http.MaxBytesReader](https://github.com/golang/go/blob/go1.26.5/src/net/http/request.go#L1176-L1225) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/request.go`, проверено 2026-07-15.
- [Исходный код JSON decoder](https://github.com/golang/go/blob/go1.26.5/src/encoding/json/decode.go#L363-L731) — репозиторий golang/go, tag go1.26.5, файл `src/encoding/json/decode.go`, функции `decodeState.value` и `decodeState.object`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
