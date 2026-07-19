---
aliases:
  - Strings, bytes, runes and UTF-8 в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# Строки, байты, руны и UTF-8

## TL;DR

String в Go — неизменяемая последовательность bytes, а не массив Unicode characters. `len(s)` и `s[i]` работают с bytes. `range` по string декодирует UTF-8 и выдаёт byte offset и rune; невалидный byte заменяется `utf8.RuneError` с шириной 1. `[]byte` нужен для изменяемых/бинарных данных, `[]rune` — когда алгоритму действительно нужна последовательность Unicode code points.

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS и GOARCH: не влияют.
- Кодировки: string может содержать любые bytes и не обязан быть валидным UTF-8; эта кодировка появляется в literals и в операциях декодирования.

## Ментальная модель

Разделяйте четыре уровня:

1. **Byte** (`byte`, alias `uint8`) — единица хранения.
2. **Rune** (`rune`, alias `int32`) — Unicode code point, но не обязательно допустимый scalar value в произвольном integer.
3. **UTF-8** — кодировка Unicode scalar values в bytes с переменной длиной; surrogate code points в неё не входят.
4. **Grapheme cluster** — то, что пользователь воспринимает как один символ; может состоять из нескольких runes и не выделяется стандартной операцией языка.

Поэтому «длина строки» не имеет единственного смысла. Нужны разные операции для bytes, runes и пользовательских символов.

## Как устроено

- String неизменяем (immutable): его bytes нельзя присваивать по индексу. Это позволяет безопасно делить одно содержимое между значениями при условии соблюдения обычных гарантий памяти.
- String literal без raw-backticks интерпретирует escapes и должен содержать допустимый UTF-8 source text; после построения string всё равно может содержать произвольные bytes.
- `len(s)` возвращает число bytes за `O(1)`.
- `s[i]` возвращает byte; индекс должен быть в диапазоне.
- `for i, r := range s` декодирует последовательность как UTF-8. `i` — byte offset начала rune.
- `utf8.RuneCountInString` считает декодированные runes за `O(n)`, включая `RuneError` для ошибочных последовательностей.
- Конверсия `[]rune(s)` декодирует весь string и выделяет память; обратная конверсия кодирует runes в UTF-8.

Ни rune count, ни byte count не равны числу grapheme clusters для combining marks, emoji sequences и некоторых письменностей. Если предметная операция работает с видимыми символами, нужна библиотека сегментации Unicode с явно выбранной версией Unicode.

## Код

```go
package main

import (
	"fmt"
	"unicode/utf8"
)

func main() {
	s := "Go, мир"
	fmt.Println(len(s), utf8.RuneCountInString(s))
	fmt.Printf("%x\n", s[4])

	first := true
	for i, r := range s {
		if !first {
			fmt.Print(" ")
		}
		fmt.Printf("%d:%c", i, r)
		first = false
	}
	fmt.Println()

	bad := string([]byte{0xff, 'A'})
	first = true
	for i, r := range bad {
		if !first {
			fmt.Print(" ")
		}
		fmt.Printf("%d:%U", i, r)
		first = false
	}
	fmt.Println()
}
```

## Ожидаемый результат

```text
10 7
d0
0:G 1:o 2:, 3:  4:м 6:и 8:р
0:U+FFFD 1:U+0041
```

Каждая кириллическая rune занимает два bytes, поэтому offsets идут `4, 6, 8`. Byte `0xff` не начинает допустимую UTF-8 sequence и декодируется как `RuneError` ширины 1.

## Trade-offs

String выражает immutable text или immutable bytes и годится как map key. `[]byte` позволяет in-place обработку и естественен для I/O buffers, но не comparable и требует явного владения; его aliasing, `len` и `cap` подчиняются [[60 Go/Массивы и слайсы|правилам слайсов]]. Частые конверсии между ними обычно добавляют копирование и allocations; оптимизировать их следует по профилю.

`[]rune` упрощает индексирование по code points, но расходует до четырёх bytes на rune плюс allocation и всё ещё не решает grapheme clusters. Однопроходный `range` обычно дешевле и точнее выражает streaming-обработку.

Нормализация Unicode может быть нужна для поиска или равенства пользовательского текста, но меняет данные и требует предметного решения. Побайтовое `s1 == s2` намеренно не нормализует строки.

## Типичные ошибки

**Неверное предположение:** `len` возвращает число символов. **Симптом:** обрезка ломает UTF-8 или UI считает неверную длину. **Причина:** `len` считает bytes. **Исправление:** определить нужную единицу и применить byte/rune/grapheme-aware алгоритм.

**Неверное предположение:** `s[i]` — rune. **Симптом:** для не-ASCII получается часть кодировки. **Причина:** индексирование string возвращает byte. **Исправление:** использовать `range` или `utf8.DecodeRuneInString`.

**Неверное предположение:** rune — видимый символ. **Симптом:** combining mark или emoji sequence разрезается. **Причина:** grapheme cluster может включать несколько code points. **Исправление:** сегментировать по Unicode grapheme boundaries, если этого требует продукт.

**Неверное предположение:** произвольный string всегда valid UTF-8. **Симптом:** replacement runes, отказ внешней системы или незаметное изменение данных; например, [[60 Go/Пакет encoding-json|encoding/json]] заменяет недопустимые последовательности. **Причина:** string способен хранить любые bytes. **Исправление:** валидировать `utf8.ValidString` на доверительной границе либо хранить бинарные данные как `[]byte`.

## Когда применять

- Используйте string для неизменяемых имён, протокольных полей и текста, когда кодировка известна.
- Обрабатывайте bytes на границе I/O; [[60 Go/Пакеты io и bufio|`io` и `bufio`]] позволяют сохранить потоковую модель, а декодирование выполняйте ровно там, где появляется текстовая семантика.
- Не материализуйте `[]rune`, если достаточно одного прохода range.
- Формулируйте лимиты API в точных единицах: bytes, code points или grapheme clusters.

## Источники

- [The Go Programming Language Specification: String types, Rune literals, String literals, Conversions, range over strings](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Strings, bytes, runes and characters in Go](https://go.dev/blog/strings) — The Go Project, Go 1.x, проверено 2026-07-15.
- [Package unicode/utf8](https://pkg.go.dev/unicode/utf8@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
