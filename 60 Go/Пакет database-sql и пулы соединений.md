---
aliases:
  - Пакет database/sql и пулы соединений
tags:
  - область/go
статус: проверено
---

# Пакет database/sql и пулы соединений

## TL;DR

`*sql.DB` — не одно соединение, а конкурентно-безопасный handle, управляющий пулом физических соединений через database driver. `QueryContext` или `ExecContext` временно получает connection; завершение операции и закрытие `Rows` возвращают его в pool.

Настройки `MaxOpenConns`, `MaxIdleConns`, `ConnMaxIdleTime` и `ConnMaxLifetime` образуют bounded resource pool. Слишком высокий предел перегружает БД, слишком низкий превращает pool в semaphore с очередью и может вызвать application-level deadlock.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: семантика `database/sql` переносима; отмена и типы значений зависят от driver и СУБД.
- Пакеты: `database/sql`, `database/sql/driver`.
- Вне scope: SQL dialect, конкретный driver, ORM и transaction isolation конкретной БД.

## Ментальная модель

`sql.DB` — диспетчер ограниченного набора connections. Операция проходит `wait for slot → acquire/create connection → driver call → release/discard connection`. `Rows`, `Tx` и выделенный `sql.Conn` удерживают ownership дольше одного вызова.

Из этого следует: забытый `Rows.Close` ведёт к утечке памяти и удерживает slot пула. От `MaxOpenConns` зависят performance, backpressure и риск application-level deadlock.

## Как устроено

`sql.Open` обычно не устанавливает сеть немедленно; он проверяет имя зарегистрированного driver и возвращает handle. Доступность проверяет `PingContext`. Один `DB` безопасен для многих goroutines и обычно живёт весь срок процесса.

Если есть idle connection, операция переиспользует его. Иначе при числе open меньше `MaxOpenConns` opener создаёт новый; при достигнутом пределе caller ждёт освобождения или отмены context. `DB.Stats` показывает `OpenConnections`, `InUse`, `Idle`, `WaitCount` и `WaitDuration`, позволяя отличить медленную БД от ожидания собственного pool.

`SetMaxIdleConns` ограничивает тёплый запас. `SetConnMaxIdleTime` убирает connections после простоя, `SetConnMaxLifetime` — после общего возраста; lifetime полезен при балансировке и server-side limits, но слишком короткое значение создаёт churn.

`QueryContext` возвращает `*Rows`, который удерживает connection до `Close` или исчерпания результата. После цикла обязательно проверяют `Rows.Err`. `QueryRowContext` откладывает ошибку до `Scan`. `Tx` закреплён за одним connection; нельзя смешивать `DB`-вызовы с транзакцией в ожидании общей atomicity.

## Код

```go
package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"sync/atomic"
)

type fakeConnector struct {
	opens atomic.Int64
}

func (c *fakeConnector) Connect(context.Context) (driver.Conn, error) {
	c.opens.Add(1)
	return &fakeConn{}, nil
}

func (c *fakeConnector) Driver() driver.Driver { return fakeDriver{} }

type fakeDriver struct{}

func (fakeDriver) Open(string) (driver.Conn, error) {
	return nil, errors.New("use Connector")
}

type fakeConn struct{}

func (*fakeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("not implemented")
}
func (*fakeConn) Close() error              { return nil }
func (*fakeConn) Begin() (driver.Tx, error) { return nil, errors.New("not implemented") }
func (*fakeConn) Ping(context.Context) error { return nil }

func main() {
	connector := &fakeConnector{}
	db := sql.OpenDB(connector)
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	for range 2 {
		if err := db.PingContext(context.Background()); err != nil {
			panic(err)
		}
	}

	stats := db.Stats()
	fmt.Println("physical opens:", connector.opens.Load())
	fmt.Printf(
		"open=%d idle=%d in-use=%d\n",
		stats.OpenConnections,
		stats.Idle,
		stats.InUse,
	)
}
```

## Ожидаемый результат

```text
physical opens: 1
open=1 idle=1 in-use=0
```

Два последовательных `PingContext` используют один physical connection: после первого вызова он возвращается в idle pool и затем берётся снова. Fake driver нужен только для самодостаточного наблюдения pool без внешней БД. Пример выполнен в официальном Go Playground на Go 1.26.5; открыто одно physical connection и итоговая статистика совпала с ожидаемой, проверено 2026-07-15.

## Trade-offs

- Большой `MaxOpenConns` повышает доступный параллелизм до насыщения БД, после чего увеличивает contention и tail latency. Малый предел защищает БД, но создаёт ожидание внутри процесса: это [[60 Go/Backpressure|backpressure]], который нужно выбирать по capacity БД и наблюдать через `WaitCount`.
- Большой idle pool уменьшает connect latency после burst, но держит server resources и sockets. `ConnMaxIdleTime` позволяет сохранить burst capacity и позже вернуть ресурс.
- `DB`-операции проще и допускают свободный connection на каждый вызов. `Tx` или `sql.Conn` нужны, когда последовательность обязана остаться на одном connection, ценой более долгого удержания slot.

## Типичные ошибки

- Предположение: `sql.Open` подтверждает доступность БД. Симптом: приложение стартует успешно, а первый request падает. Причина: handle создаётся лениво. Исправление: `PingContext` в startup policy с ограниченным [[60 Go/Context, deadlines и распространение отмены|context]].
- Предположение: `Rows` освободится сборщиком мусора. Симптом: растут `InUse`, `WaitCount` и latency. Причина: connection удерживается result set. Исправление: сразу `defer rows.Close()`, дочитать rows и проверить `rows.Err()`.
- Предположение: повышение `MaxOpenConns` лечит любую очередь. Симптом: БД перегружается, запросы становятся ещё медленнее. Причина: bottleneck перенесён за пределы процесса. Исправление: согласовать pool с capacity, concurrency limit и SLO.
- Предположение: вызов `db.ExecContext` внутри логики `Tx` входит в транзакцию. Симптом: часть изменений commit независимо. Причина: `DB` может выбрать другой connection. Исправление: все операции транзакции вызывать через `*sql.Tx`.

## Когда применять

Используйте один долгоживущий `*sql.DB` на логическую базу и конфигурацию driver. Передавайте request context в `QueryContext`/`ExecContext`, задавайте pool limits из capacity-модели и наблюдайте `DB.Stats`. Закрытие handle должно входить в общий [[60 Go/Graceful shutdown|shutdown protocol]] после остановки новых запросов.

Для долгих result sets учитывайте, что streaming удерживает connection. Иногда pagination или materialization меньшего результата выгоднее, чем долго занимать редкий slot; выбор isolation, индексов и формы запроса относится к [[30 Данные/Карта — Данные|карте данных]].

## Источники

- [Документация пакета database/sql](https://pkg.go.dev/database/sql@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Managing connections](https://go.dev/doc/database/manage-connections) — Go project, документация `database/sql`, проверено 2026-07-15.
- [Исходный код пула database/sql](https://github.com/golang/go/blob/go1.26.5/src/database/sql/sql.go#L507-L586) — репозиторий golang/go, tag go1.26.5, файл `src/database/sql/sql.go`, тип `DB`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
