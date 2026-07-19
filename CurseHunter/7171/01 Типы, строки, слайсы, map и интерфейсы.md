---
aliases:
  - Go-задачи — GO ПРОРВЁМСЯ
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/собеседования
статус: проверено
---

# Типы, строки, слайсы, map и интерфейсы

## Как читать задачи «что выведет программа»

Надёжнее не вспоминать готовый ответ, а каждый раз восстановить три уровня состояния:

1. **Значение:** что скопировано при присваивании, передаче аргумента или регистрации `defer`.
2. **Descriptor:** куда указывают pointer, slice header, string header или dynamic pair интерфейса.
3. **Backing storage:** какой объект реально меняется и не произошла ли замена backing array после `append`.

Полная теория уже собрана в [[CurseHunter/6609/Бланк вопросов и заданий|курсе 6609]]. Здесь сохранены конкретные задачи курса 7171, их наблюдаемый вывод и уточнения, которыми интервьюер обычно меняет исход.

## Значения, указатели и `defer`

### 27. Копия структуры и переназначение указателя

![[90 Вложения/CurseHunter/7171/Кадры/7171-27-копирование-указателя.jpg]]

*Кадр урока 27: исходный код и наблюдаемый результат задачи на копирование значения и указателя.*

Упрощённая форма задачи:

```go
type User struct{ Name string }

func updateUser(u User) {
	u.Name = "Таненбаум"
	fmt.Println(u.Name)
	resetUser(&u)
	fmt.Println(u.Name)
}

func resetUser(u *User) {
	u = &User{Name: "Безымянный"}
	fmt.Println(u.Name)
}
```

`main` создаёт `User{Name: "Олег"}`, печатает имя до и после `updateUser`. Наблюдаемый порядок:

```text
Олег
Таненбаум
Безымянный
Таненбаум
Олег
```

`updateUser` меняет собственную копию структуры. `resetUser` получает адрес этой копии, но присваивание `u = &User{...}` меняет лишь локальную переменную-pointer; прежний объект не перезаписывается. Поэтому после возврата в `updateUser` имя снова «Таненбаум», а объект в `main` всё время остаётся «Олег».

Follow-up различает три операции:

- `u.Name = "Безымянный"` меняет объект, на который указывает `u`;
- `*u = User{Name: "Безымянный"}` перезаписывает весь этот объект;
- `u = &User{...}` лишь переназначает локальную копию pointer.

### 28. Когда `defer` видит старое, а когда новое значение

```go
x, y := 10, 20

defer func(v int) { fmt.Println("x:", v) }(x)
defer func() { fmt.Println("y:", y) }()

x = 100
y = 200
fmt.Println("Конец main")
```

Наблюдаемый вывод:

```text
Конец main
y: 200
x: 10
```

Аргумент `x` вычислен при регистрации первого `defer`, поэтому сохранено `10`. Второй closure читает переменную `y` при выполнении и видит `200`. Deferred calls выполняются LIFO.

### 29. Аргументы `defer`, pointer и переназначение переменной

Создаётся `account` с балансом `1000`, затем регистрируются:

```go
defer printBalance("Изначальный баланс", account.Balance)
defer printBalance("Текущий баланс", account.Balance)
defer printAccountBalance("Указатель на баланс", account)
```

После регистрации первый объект меняется `1000 → 1500 → 1300`, а переменная `account` переназначается на новый объект с балансом `300`.

Deferred calls выполняются в обратном порядке. Два `int`-аргумента уже равны `1000`. Pointer-аргумент тоже вычислен заранее, но указывает на первый mutable object и при возврате видит `1300`. Итог:

```text
Указатель на баланс: 1300
Текущий баланс: 1000
Изначальный баланс: 1000
```

Фраза «аргументы `defer` вычисляются сразу» не означает deep copy reachable object graph: копируется значение pointer, а не объект за ним.

### 30. Pointer на элемент среза пережил `append`, но остался в старом массиве

Исходный `cars` имеет `len=3`, `cap=3`. `carPtr := &cars[0]`, пробег увеличивается `5000 → 5100`, затем `append` четвёртого элемента создаёт новый backing array. После этого `carPtr.mileage += 50` меняет старый массив, а `cars[0]` находится уже в новом.

Наблюдаемый результат:

```text
cars[0]: 5100 red
carPtr:  5150 red
```

Pointer остаётся memory-safe благодаря GC, но логически устаревает. Нельзя хранить адрес элемента растущего среза, если дальнейший код ожидает, что он всегда адресует текущий backing array. Более устойчивые варианты: индекс, заранее достаточная capacity или slice of pointers с отдельно аллоцированными объектами.

### 31. Массив передаётся целиком, срез — descriptor

```go
func modifyArray(a [3]int) { a[0] = 10 }
func modifySlice(s []int)  { s[0] = 10 }

array := [3]int{1, 2, 3}
slice := array[:]
```

`modifyArray(array)` меняет копию; `array` остаётся `[1 2 3]`. `modifySlice(slice)` получает копию slice header, но оба descriptor указывают на один array, поэтому `array` и `slice` становятся `[10 2 3]`.

Full slice expression `a[low:high:max]` дополнительно ограничивает capacity до `max-low`. Это способ заставить следующий `append` отделить результат от хвоста исходного массива и тем самым сделать ownership boundary явнее.

### 32. Deferred method с value receiver, pointer receiver и wrapper closure

```go
type X struct{ Val int }
func (x X) S() { fmt.Println(x.Val) }

x := X{Val: 10}
defer x.S()
x.Val = 256
```

С value receiver deferred call сохраняет копию receiver при регистрации и печатает `10`. Если `S` имеет receiver `*X`, compiler берёт адрес addressable `x`; сохранённый pointer при возврате видит `256`. Если написать `defer func() { x.S() }()`, сам method call произойдёт внутри closure при возврате, поэтому value receiver скопирует уже обновлённый `x` и тоже напечатает `256`.

### 33. Field alignment меняет размер структуры

```go
type Foo struct {
	a bool
	b int32
	c bool
}

type Bar struct {
	a bool
	c bool
	b int32
}
```

На показанной 64-bit platform `unsafe.Sizeof(Foo{}) == 12`, а `unsafe.Sizeof(Bar{}) == 8`. В `Foo` нужны три байта padding перед `int32` и три байта tail padding; в `Bar` два `bool` соседствуют, затем два байта padding выравнивают `int32`.

Это implementation/platform-dependent layout, а не обещание одинакового числа на всех architectures. Практическое правило — группировать поля по убыванию alignment, но не ломать ради нескольких байтов смысловую целостность объекта, API и cache locality реального access pattern.

## Строки и Unicode

### 34. Квадратичная конкатенация

Курс предлагает найти проблемы в цикле:

```go
str := ""
for i := 0; i < 100_000; i++ {
	str += fmt.Sprintf("%d", i)
}
```

Строки immutable: повторное `+=` обычно создаёт новое хранилище и копирует накопленный prefix, поэтому суммарный объём копирования может расти квадратично. `fmt.Sprintf` добавляет parsing формата и interface overhead.

Для такого append-only построения нужны `strings.Builder`, `strconv.AppendInt`/`strconv.Itoa` и, если размер предсказуем, `Builder.Grow`. Показанные в видео wall-clock числа зависят от hardware, compiler и benchmark setup; переносимым выводом является не конкретное ускорение, а уменьшение числа allocations и повторного копирования. Проверять надо `go test -bench . -benchmem` на целевой версии.

### 35. `len` считает bytes, а не символы

![[90 Вложения/CurseHunter/7171/Кадры/7171-35-bytes-и-runes.jpg]]

*Кадр урока 35: строка `"ddЯй"` занимает шесть bytes, но содержит четыре runes.*

Для строки `"ddЯй"` видео показывает:

```text
len: 6
utf8.RuneCountInString: 4
```

Два ASCII characters занимают по одному byte, две кириллические буквы — по два UTF-8 bytes. `[]rune(s)` и `range s` работают с Unicode code points, но и это не число пользовательских grapheme clusters: combining marks и emoji sequences могут состоять из нескольких runes.

### 36. Индексный и `range`-обход строки

`s[i]` возвращает byte. Форматирование каждого byte через `%c` корректно только для ASCII; multibyte UTF-8 sequence превратится в отдельные неправильные characters. `for byteOffset, r := range s` декодирует runes и возвращает byte offset начала каждой rune.

Надо различать три задачи:

- нужны raw bytes — индексный цикл;
- нужны code points — `range` или `[]rune`;
- нужны пользовательские characters — Unicode grapheme segmentation, которой стандартный `range` не делает.

### 37. Строку нельзя менять по индексу

Курс начинает с `s := "Dest"` и `println(s[0])`: результат — integer value первого byte (`68`), а не строка `"D"`. Присваивание `s[0] = 'R'` не компилируется, потому что элементы строки immutable.

Для ASCII достаточно `b := []byte(s); b[0] = 'R'; s = string(b)`. Показанный универсальный вариант использует `[]rune`, меняет первую rune и получает `"Rest"`; он сохраняет UTF-8 code points, но аллоцирует новый backing storage.

### 38. Обычная и `unsafe`-конвертация `[]byte → string`

```go
b := []byte("hello world")
s1 := string(b)
s2 := *(*string)(unsafe.Pointer(&b))
b[0] = 'R'
```

Обычная conversion создаёт string value, не зависящее от последующей мутации `b`, поэтому `s1 == "hello world"`. `s2` незаконно разделяет mutable bytes со string representation и после записи наблюдаемо становится `"Rello world"`.

Zero-copy через `unsafe` не является обычной оптимизацией: нарушается базовый контракт immutable strings, возникают aliasing/lifetime risks, а дальнейшее поведение кода может зависеть от compiler optimizations. Начиная с Go 1.20 есть `unsafe.String`, но его документация также требует не менять bytes, пока string существует. Production-код должен начинать с безопасной conversion и менять её только после profile evidence и строгого ownership protocol.

## Срезы и backing array

### 39. `append` в subslice перезаписывает исходный хвост

```go
data := []int{10, 20, 30, 40}
modify(data[:2])

func modify(s []int) {
	s = append(s, 50, 60)
}
```

У `data[:2]` capacity остаётся `4`, поэтому append помещает `50,60` в существующий backing array. Внешний slice header не меняется, но его элементы становятся `[10 20 50 60]`.

Если добавить третий элемент, capacity не хватит и локальный `s` перейдёт на новый array; внешний `data` тогда останется без третьей локальной записи. Чтобы запретить перезапись хвоста заранее, передавать `data[:2:2]`.

### 40. Два `append` от общей базы

Если `a1 := []int{1,2,3,4,5}` имеет `cap=5`, то `a2 := append(a1,6)` и `a3 := append(a1,7)` получают разные новые arrays: результат предсказуемо заканчивается на `6` и `7` соответственно.

Если `a1` заранее создан с запасом capacity, оба append используют один свободный slot backing array. Второй append записывает `7` поверх `6`, поэтому и `a2`, и `a3` могут наблюдать хвост `7`. Важен не исходный syntax, а фактические `len/cap` и alias graph.

### 41. Изменение элемента и изменение длины — разные эффекты

```go
func modifyElement(s []int) { s[1] = 999 }

func addElement(s []int) {
	s = append(s, 100)
	s[0] = 888
}
```

Для `original := []int{10,20,30}` первая функция оставляет внешний результат `[10 999 30]`. Во второй append при заполненной capacity создаёт новый backing array, поэтому локальная запись `888` не видна снаружи, а внешний slice остаётся `[10 999 30]`. Даже если append не аллоцирует, внешний `len` всё равно не увеличится: slice header передан по значению.

Чтобы функция действительно добавляла элементы в логический результат, обычно возвращают новый slice и присваивают его у caller. Pointer на slice header нужен реже и усложняет ownership.

### 42. Сгенерировать `n` уникальных случайных чисел

Показанное решение генерирует `rand.Int()`, проверяет membership в `map[int]struct{}` и добавляет unseen values, пока длина результата не станет `n`.

Контракт задачи недоопределён без диапазона и требований к randomness:

- при unbounded-looking `int` space collisions редки, но алгоритм всё равно probabilistic;
- для диапазона размера `M` необходимо `n <= M`, иначе цикл не завершится;
- при `n` близком к `M` rejection sampling резко замедляется, и лучше shuffle/permutation;
- `math/rand` не подходит для security tokens — там нужен `crypto/rand`;
- отрицательный `n` нельзя передавать как capacity в `make`.

### 43. Предсказать capacity subslice

Для `data := make([]int, 5, 10)` срез `data[1:]` имеет `len=4`, `cap=9`: capacity считается до конца backing array, а не до прежнего `len`. Следующее взятие `[2:]` уже от этого subslice даёт `len=2`, `cap=7` и начинается с исходного индекса `3`.

Созданный заранее `dataNew := make([]int, 0, 3)` теряет свою allocation, если сразу присвоить `dataNew = sliceCapacityDemo(data, 2)`: assignment заменяет весь descriptor. Формула для двухиндексного slice `a[low:high]`: `len=high-low`, `cap=cap(a)-low`.

### 44. Два append через subslice разного размера

```go
nums := []int{1, 2, 3}
addNum(nums[:2])
fmt.Println(nums)
addNums(nums[:2])
fmt.Println(nums)

func addNum(s []int)  { s = append(s, 4) }
func addNums(s []int) { s = append(s, 5, 6) }
```

Первый append помещается в `cap=3` и перезаписывает третий элемент: внешний `nums` становится `[1 2 4]`. Второму нужны четыре позиции при capacity три, поэтому он создаёт новый array, локальный результат теряется, а повторная печать остаётся `[1 2 4]`.

Заголовок урока говорит об оптимизации append в цикле, но наблюдаемое видео разбирает именно aliasing и порог realloc. Оптимизация цикла сводится к другому правилу: если итоговая длина предсказуема, заранее выделить capacity через `make([]T, 0, n)` и всё равно сохранять каждый результат `s = append(s, x)`.

### 45. Pointer на элемент после роста среза — ещё один вариант

`people := make([]person, 2)`, затем `p := &people[1]` и `p.age++`. Append ещё трёх элементов вынуждает выделить новый array; значение `age=1` копируется в него. Следующий `p.age++` меняет старый array. Поэтому видео получает:

```text
people[1].age: 1
p.age:         2
```

Capacity после роста в показанном запуске равна `6`, но это implementation detail growth algorithm. Единственная необходимая для ответа гарантия — прежней capacity `2` недостаточно для длины `5`, следовательно backing array обязан смениться.

### 46. Потерянный append и несколько одинаковых pointers

```go
numbers := make([]*int, 0, 5)
var number int
for range 3 {
	number++
	numbers = append(numbers, &number)
}
appendLenWrong(numbers)
```

Все три элемента указывают на одну переменную `number`, поэтому после цикла разыменование даёт `3 3 3`. Функция `appendLenWrong(numbers []*int)` получает копию header; даже при достаточной capacity caller's length остаётся `3`, если функция не вернула новый slice. Исправления:

- для отдельных значений создавать отдельную переменную/объект на итерацию;
- для изменения длины возвращать `numbers = appendLen(numbers)`;
- pointer на slice header допустим, но обычно менее идиоматичен и не решает проблему общего `number`.

Семантика loop variables Go 1.22 здесь не спасает: переменная `number` объявлена снаружи и намеренно общая для всех итераций.

### 47. Перекрывающиеся subslices и append без realloc

![[90 Вложения/CurseHunter/7171/Кадры/7171-47-slice-aliasing.jpg]]

*Кадр урока 47: наблюдаемый результат показывает aliasing общего backing array.*

`original := []int{0,1,2,3,4,5,6,7,8,9}`, `slice1 := original[2:5]`, `slice2 := original[3:7]`. Запись `slice1[0] = 999` меняет `original[2]`. Затем `append(slice1, 100, 200)` помещается в capacity `8` и записывает значения в исходные индексы `5` и `6`, которые входят и в `slice2`.

Наблюдаемый результат:

```text
slice1:   [999 3 4 100 200]
original: [0 1 999 3 4 100 200 7 8 9]
slice2:   [3 4 100 200]
```

Заголовок метаданных называет урок «утечкой памяти через append», но в видео показан другой failure mode — неожиданная мутация перекрывающихся views. Классическая retention-проблема возникает, когда маленький subslice долго удерживает большой backing array; исправление — скопировать нужный фрагмент, например `dst := append([]T(nil), src[low:high]...)`.

## `map`

### 48. Атомарный `GetOrCreate`

Две goroutines одновременно вызывают `GetOrCreate("key1", differentValue)`. Проверка под `RLock`, затем освобождение read lock и безусловная запись под `Lock` содержит TOCTOU race на уровне протокола: обе goroutines могут не увидеть key и последовательно записать разные values.

Исправление из курса — double-check после получения exclusive lock. Инвариант: linearization point создания находится внутри `Lock`; только первая goroutine записывает, остальные возвращают уже сохранённое значение. Обычный data race mutex устраняет, но без второй проверки семантика «создать ровно один раз» всё равно нарушена.

### 49. История состояний `map` из канала

Producer обновляет один `map[string]int` и несколько раз отправляет его в канал; consumer складывает полученные maps в slice. `map` — reference-like descriptor, поэтому history хранит несколько aliases одного mutable state и в конце показывает одинаковую последнюю версию.

Если требуется snapshot history, producer перед каждой отправкой обязан клонировать map (`maps.Clone` в Go 1.21+ или явный цикл). Дополнительно канал должен иметь ownership contract: после передачи snapshot producer его больше не меняет; consumer читает `for stock := range ch`, а producer закрывает канал.

### 50. Bounded WordCounter: FIFO не равен LRU

![[90 Вложения/CurseHunter/7171/Кадры/7171-50-fifo-не-lru.jpg]]

*Кадр урока 50: фактический порядок вытеснения позволяет проверить, обновляется ли recency при чтении.*

Курс считает слова и хранит не более трёх keys. Для последовательности `apple, banana, apple, orange, grape, banana, kiwi` наблюдается:

```text
map[grape:1 kiwi:1 orange:1]
order = [orange grape kiwi]
```

Показанная реализация удаляет самый старый **вставленный** key и не перемещает key при повторном обращении. Это FIFO eviction, хотя заголовок называет задачу LRU. Настоящий LRU должен обновлять recency на hit и поддерживать `map[key]*list.Element` плюс doubly linked list, чтобы `Get/Put/evict` были `O(1)`.

Уточнить `limit <= 0`, concurrent access и семантику counter при eviction/reinsertion. Map iteration не может заменить order structure, потому что его порядок не определён.

### 51. Объединить values без дубликатов

Для `map[string][]string` надо добавить `newValues` по key, сохранив существующий порядок и не добавив повторы. Строим set из уже сохранённых values, затем одним проходом по `newValues` добавляем unseen и сразу отмечаем их в set. Последнее действие важно, иначе два одинаковых new values оба попадут в результат.

В видео используется пример `group1: [apple banana]` плюс `[banana cherry cherry]`; результат для `group1` — `[apple banana cherry]`. Для отсутствующего key тот же алгоритм работает с nil slice. Сложность `O(old+new)` времени и `O(unique)` памяти.

### 52. `sync.Map` как cache и duplicate computation

`GetOrCompute(key, compute)` сначала делает `Load`, при miss вычисляет value и вызывает `LoadOrStore`. Это гарантирует единственное сохранённое value, но не единственное выполнение дорогой функции: несколько goroutines могут параллельно пройти miss и вычислить одно и то же.

Если duplicate work допустима, `LoadOrStore` корректно выбирает winner. Если нужна single-flight семантика, в cache надо хранить per-key promise/entry или использовать `singleflight.Group`; mutex вокруг всей computation исключит дубли, но сериализует разные keys. `sync.Map` оптимизирован не как универсальная замена `map+mutex`, а для специализированных access patterns, описанных в документации.

### 53. Порядок обхода `map`

Цикл `for k, v := range map[int]string{1:"a",2:"b",3:"c"}` не имеет определённого порядка. Нельзя обещать insertion order, sorted order или стабильный порядок между запусками. Runtime deliberately perturbs iteration, но точный seed и traversal — implementation detail.

Для deterministic output собрать keys в slice, отсортировать и обращаться к map по ним. Для протокола/теста нельзя сравнивать сериализацию, зависящую от raw map iteration, если serializer сам не гарантирует canonical order.

## Интерфейсы и ошибки

### 54. Type assertion меняет static interface

`*User` реализует методы `Get/List/Create/Delete`. Значение сначала лежит в `Reader`, затем успешно утверждается как `Writer`, потому что dynamic type `*User` реализует оба интерфейса. Но переменная результата имеет static type `Writer`, поэтому вызов `userWriter.Get()` не компилируется: в method set `Writer` нет `Get`.

Assertion проверяет dynamic type, но результат ограничивается выбранным static interface. Если нужны оба контракта, объявить composed interface `interface { Reader; Writer }`, сделать assertion к нему либо не терять исходное concrete value.

### 55. Вернуть ошибку без пакетов `errors` и `fmt`

Достаточно собственного типа с методом `Error() string`:

```go
type CustomError struct{ message string }
func (e CustomError) Error() string { return e.message }

func handle() error {
	return CustomError{message: "произошла ошибка"}
}
```

Если `Error` имеет pointer receiver, `handle` должен вернуть `&CustomError{...}`. Выбор receiver влияет на method set, comparability и возможность typed nil. Для production error полезно хранить structured fields и поддерживать wrapping/`Unwrap`, но это уже расширение контракта.

### 56. Method sets value и pointer types

В исходной версии `CreditCardProcessor.Process` имеет pointer receiver, а `Verify` — value receiver. Поэтому `CreditCardProcessor` value не реализует интерфейс с обоими методами, а `*CreditCardProcessor` реализует. У `PayPalProcessor` оба метода pointer-receiver, поэтому интерфейс также принимает только pointer.

Compiler автоматически вставляет `&` при direct call на addressable value, но interface assignment/argument не получает недостающий pointer method автоматически. Это типичная ловушка: «я могу вызвать метод на переменной» не означает, что value type входит в нужный interface method set.

После перевода processors на pointers в видео второй PayPal payment меняет баланс `200 → 50`, поэтому следующая проверка суммы `150` уже не проходит. Mutable state — ещё одна причина выбирать pointer receiver последовательно.

### 57. Нетипизированный cache и panic на assertion

`Load(key) interface{}` смешивает две неопределённости: key может отсутствовать, а dynamic type value может отличаться от ожидаемого. Выражение `cache.Load("width").(float64)` panic и при nil interface, и при value другого типа.

Безопасный API возвращает `(any, bool)` для membership, после чего вызывающий отдельно делает `typed, ok := v.(T)`. Ещё лучше — typed/generic cache, если все values одного типа. Проверка `v == nil` не заменяет `ok`: key может законно хранить nil или typed-nil value.

### 58. Typed nil внутри interface

```go
var s *SomeStruct = nil
CheckForNil(s) // parameter any
```

Внутри `CheckForNil`, `i != nil`: interface содержит dynamic type `*SomeStruct` и dynamic value nil. Interface равен nil только когда обе части отсутствуют. Видео печатает «Это не nil!».

Правильное решение зависит от contract. Если функция ждёт именно pointer — принять `*SomeStruct` и сравнить напрямую. Generic «nil-like» reflection требует проверки kind и `IsNil`, но обычно сигнализирует о слишком широком API. Вызов method через typed nil может быть корректным только если сам method явно умеет работать с nil receiver.

## Проверочные вопросы

1. Почему pointer на старый элемент остаётся валидным после reallocating `append`, но становится логически stale?
2. Что именно вычисляется при регистрации deferred method: receiver value, pointer или closure environment?
3. Почему копия slice header позволяет менять элементы, но не длину caller's slice?
4. Как full slice expression создаёт ownership boundary?
5. Почему `len(s)` и `utf8.RuneCountInString(s)` оба не обязаны совпадать с количеством видимых characters?
6. При каких `len/cap` два независимых `append` alias один свободный slot?
7. Когда `strings.Builder` лучше `bytes.Buffer`, а когда нужна потоковая запись без сборки полной строки?
8. Какой contract должен сопровождать zero-copy string, чтобы исключить мутацию и premature lifetime end?
9. Почему rejection sampling уникальных чисел деградирует при заполнении диапазона?
10. Какие размеры структуры являются language guarantee, а какие зависят от implementation и architecture?

## Источники

- [Go прорвёмся](https://olezhek28.courses/gothrough) — Олег Козырев и Аня «авось прорвёмся», программа модуля Go, проверено 2026-07-19.
- [The Go Programming Language Specification](https://go.dev/ref/spec) — Go project, language version `go1.26`, проверено 2026-07-19.
- [Package unsafe](https://pkg.go.dev/unsafe) — Go project, standard library Go `1.26`, проверено 2026-07-19.
- [Package strings](https://pkg.go.dev/strings) — Go project, standard library Go `1.26`, проверено 2026-07-19.
- [Package maps](https://pkg.go.dev/maps) — Go project, standard library Go `1.26`, проверено 2026-07-19.
- [Package unicode/utf8](https://pkg.go.dev/unicode/utf8) — Go project, standard library Go `1.26`, проверено 2026-07-19.
- [Go 1.22 Release Notes — Changes to the language](https://go.dev/doc/go1.22#language) — Go project, Go 1.22, проверено 2026-07-19.
