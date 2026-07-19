---
aliases:
  - Go coding without IDE
  - Компилируемый Go-код на интервью
tags:
  - область/go
  - тема/алгоритмы
  - тема/собеседование
статус: черновик
---

# Решение алгоритмической задачи на Go без IDE и autocomplete

## TL;DR

Без IDE выигрывает небольшой предсказуемый набор конструкций: полный `package` и imports, точная сигнатура, slices/maps, короткие helpers и явный результат для отсутствия значения. Сначала пишут compilable skeleton, затем добавляют один законченный vertical slice алгоритма и только после этого оптимизируют.

Цель — снизить число состояний, которые приходится держать в голове. Не вводите generics, interface или custom container, если обычных `[]int`, `map[K]V` и двух helpers достаточно. Перед завершением проведите mental compile: imports, identifiers, types, все return paths, границы индексов, nil map writes и присваивание результата `append`.

## Область применимости

- Версия Go: 1.26; стабильная toolchain для проверки — Go 1.26.5.
- GOOS/GOARCH: семантика примера не зависит от платформы; размер `int` зависит от реализации.
- Среда: простой редактор или collaborative pad без autocomplete и автоматического запуска tests.

## Ментальная модель

Compiler проверяет синтаксис и типы, но в интервью его роль приходится частично исполнять самому. Работайте слоями:

```text
контракт -> сигнатура -> state/invariant -> основной цикл -> outcome -> tests
```

После каждого слоя код должен оставаться цельным. Если helper ещё не написан, сначала зафиксируйте его точную сигнатуру. Если standard-library API не помните уверенно, выберите маленькую ручную реализацию либо уточните, можно ли свериться с документацией; угадывание метода создаёт compile error без алгоритмической пользы.

## Как устроено

### Зафиксировать контракт типами

Выберите representation до тела функции. `string` в Go — bytes, а `range` декодирует UTF-8 в runes; нужная единица должна следовать из условия и модели из [[60 Go/Строки, байты, руны и UTF-8|заметки о строках]]. Для последовательности обычно нужен slice с aliasing/capacity semantics из [[60 Go/Массивы и слайсы|массивов и слайсов]].

Отсутствующий ответ лучше кодировать явно: `(int, bool)`, `([]int, bool)` или `error` в зависимости от контракта. Sentinel `-1` безопасен только если `-1` не может быть валидным результатом и это ясно из сигнатуры/описания.

### Написать skeleton

Минимальный порядок:

1. `package` и только реально используемые imports;
2. сигнатура функции;
3. initialization state;
4. цикл/recursion с одним invariant;
5. все return paths;
6. маленький `main` или tests для трассировки.

Go запрещает unused imports и local variables, поэтому не выписывайте будущие зависимости заранее. Map перед записью должна быть non-nil; `append` возвращает новый slice descriptor, его результат присваивают.

### Провести mental compile

Читайте код как compiler, а не как автор:

- каждое имя объявлено в доступном scope;
- аргументы и результаты совпадают по числу и типам;
- все ветви функции с результатом возвращают значение;
- `for` и `if` имеют корректные braces;
- conversions явны там, где смешиваются numeric types;
- индекс удовлетворяет `0 <= i < len(s)`;
- receiver pointer нужен, если helper меняет длину slice внутри struct.

После этого читайте как runtime: empty input, first/last element, duplicates, no result, integer bounds.

## Код

Полная программа реализует lower bound и показывает как найденную позицию, так и insertion point.

```go
package main

import "fmt"

func lowerBound(a []int, x int) int {
	lo, hi := 0, len(a)
	for lo < hi {
		mid := lo + (hi-lo)/2
		if a[mid] < x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

func main() {
	a := []int{1, 2, 2, 5}
	fmt.Println(lowerBound(a, 2))
	fmt.Println(lowerBound(a, 4))
}
```

## Ожидаемый результат

```text
1
3
```

Локальная Go toolchain недоступна; пример проверен статически, но компиляция и наблюдаемый вывод пока не подтверждены. Поэтому статус заметки остаётся `черновик`.

Первый результат указывает на первый duplicate `2`; второй — позиция перед `5`, куда можно вставить `4`. В программе нет IDE-specific scaffolding и внешних packages.

## Trade-offs

Ручная реализация небольшой структуры снижает риск забыть API, но увеличивает объём кода и число invariants. Standard library обычно короче и надёжнее, если сигнатура известна точно. Например, `slices.BinarySearch` уже возвращает position и `found`, однако собственный lower bound лучше показывает контроль над boundary contract.

Короткие имена `i`, `j`, `lo`, `hi` уместны в локальном алгоритме; для нескольких смыслов нужны имена вроде `write`, `windowLeft`, `parent`. Избыточная архитектура не улучшает maintainability десятистрочного решения.

## Типичные ошибки

**Неверное предположение:** IDE исправит мелкую неточность. **Симптом:** алгоритм верен, но код не компилируется из-за unused import или неверной сигнатуры. **Причина:** compile feedback входил в привычный цикл. **Исправление:** тренировать полный файл и отдельный mental-compile pass.

**Неверное предположение:** `append(s, x)` меняет local descriptor без присваивания. **Симптом:** длина не растёт либо результат compile-time не используется. **Причина:** `append` возвращает slice. **Исправление:** писать `s = append(s, x)` и помнить aliasing model.

**Неверное предположение:** `len(string)` считает пользовательские символы. **Симптом:** индекс режет UTF-8 encoding. **Причина:** `len` считает bytes. **Исправление:** заранее выбрать bytes/runes/graphemes и не менять единицу в середине решения.

**Неверное предположение:** после написания можно сразу объявить решение готовым. **Симптом:** off-by-one виден только на empty или last position. **Причина:** не выполнены trace и tests. **Исправление:** прогнать state по таблице и проверить все return paths.

## Когда применять

- Тренируйтесь в том же ограничении: один пустой файл, без snippets, autocomplete и debugger.
- Поддерживайте небольшой набор проверенных templates: binary search, queue с head index, heap sift-up/down, BFS/DFS.
- Если standard-library API не центрально для задачи и вы его забыли, выберите более простой код с ясным invariant.
- После каждой тренировки запускайте formatter/compiler/tests и отдельно записывайте именно compile mistakes.

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, declarations, types, control flow, built-ins и indexing, проверено 2026-07-18.
- [Package slices](https://pkg.go.dev/slices@go1.26.5) — стандартная библиотека Go, tag go1.26.5, `BinarySearch` и sorting APIs, проверено 2026-07-18.
- [SDE II Interview Prep: Coding](https://amazon.jobs/content/en/how-we-hire/sde-ii-interview-prep) — Amazon Jobs, требование syntactically correct code и практика без IDE, проверено 2026-07-18.
- [The Google Technical Interview: How to Get Your Dream Job](https://research.google.com/pubs/archive/41881.pdf) — Dean Jackson, Google Research / ACM XRDS 20(2), 2013, практика whiteboard code и объяснение решений, проверено 2026-07-18.
