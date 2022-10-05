# Actor と async データ

Internet Computer のプログラミングモデルは、メモリが分離された Canister が、Candid の値をエンコードしたバイナリデータを非同期にメッセージングして通信するというものです。 Canister はそのメッセージを一度に処理し、競合状態を防ぎます。 Canister はコールバックを使用して、Canister 間で発行したメッセージの結果に対して何をする必要があるかを登録します。

Motoko は、Internet Computer の複雑さを、よく知られている高レベルの抽象化である _Actor_ モデルで抽象化します。 各 Canister は型付けされた Actor として表現されます。Actor の型は、その Actor が扱えるメッセージのリストです。各メッセージは型付きの非同期関数として抽象化されます。 Actor 型から Candid 型への変換は、基礎となる Internet Computer の生のバイナリデータの構造を強制します。 Actor はオブジェクトに似ていますが、そのステートが完全に分離されていること、外部環境とのやりとりが完全に非同期のメッセージングによって行われること、同時進行中の Actor によって並列に発行されたメッセージであっても一度に処理されることが異なります。

Motoko では、Actor へのメッセージ送信は関数呼び出しですが、呼び出しが戻るまで発信側をブロッキングするのではなく、メッセージが受信側のキューに入り、リクエストが保留中であることを表す _future_ が発信側にすぐに返されます。 future は、発信側がリクエストを実行したときの最終的な結果に対するプレースホルダーであり、後でクエリすることができます。 リクエストを発行してから結果を待つまでの間、発信側は同じ Actor や他の Actor にさらにリクエストを発行するなど、他の作業を自由に行うことができます。 受信側がリクエストを処理すると、future が完了し、その結果が発信側に返され利用できるようになります。 発信側が future を待っている場合は、結果が返り次第処理を再開するか、そうでない場合は結果を後で使用できるように future に保存します。

Motoko では、Actor は専用の構文と型を持っています。メッセージングは、future を返す _shared_ 関数と呼ばれる関数で処理されます（リモートの Actor が利用できるため、shared と呼ばれます）。 ここで、future の `f` が、ある型 `T` に対する特別な型である `async T` の値であるとします。 `f` が完了するのを待つことは、`await f` を使って `T` 型の値を得ることで表現されます。 メッセージングにおいて共有ステートを持たないようにするには、例えばオブジェクトや可変配列を送信するなどの方法があります。 shared 関数で送信できるデータは、不変の _shared_ 型に制限されています。

はじめに、最も単純でステートフル（状態を保持する）な Service を考えてみましょう。以前のローカル `counter` オブジェクトの分散バージョンである `Counter` Actor です。

## 例：カウンタの Service

以下のような Actor の宣言を考えます。

```motoko file=./examples/counter-actor.mo

```

`Counter` Actor は、1 つのフィールドと 3 つのパブリックな _shared_ 関数を宣言しています。

- フィールド `count` は可変で、0 に初期化され、暗黙的に `private` となります。

- 関数 `inc()` は、非同期的にカウンタをインクリメントし、同期のために `async ()` 型の future を返します。

- 関数 `read()` は、非同期にカウンタの値を読み込み、その値を含む `async Nat` 型の future を返します。

- 関数 `bump()` は、非同期的にカウンタをインクリメントし、値を読み込みます。

shared 関数は、ローカル関数とは異なり、リモートの呼び出し元からアクセス可能です。さらに、引数と戻り値は _shared_ 型でなければならないという追加の制限があります。shared 型はイミュータブルなデータ、Actor の参照、shared 関数の参照などを含む型のサブセットですが、ローカル関数への参照とミュータブルなデータは含まれません。Actor とのやりとりはすべて非同期で行われるので、Actor の関数は必ず future を返さなければなりません。つまり、ある型 `T` に対して `async T` という形の型を返さなければなりません。

`Counter` Actor のステート（`count`）を読み取ったり変更したりするには、shared 関数を使用するしかありません。

`async T` 型の値は future です。future の生成元は、値またはエラーの結果を返した時点で future を完了させます。

オブジェクトやモジュールとは異なり、Actor は関数のみを公開することができ、それらは `shared` 関数である必要があります。このため Motoko では、パブリックな Actor 関数の `shared` 修飾子を省略することができ、より簡潔に同じ Actor を宣言することが可能になっています。

```motoko name=counter file=./examples/counter-actor-sugar.mo

```

現在、shared 関数を宣言できるのは、Actor や Actor クラスのボディの中だけです。このような制限はあるものの、shared 関数は Motoko の第一級関数であり、引数や返り値として渡したり、データ構造に格納したりすることができます。

shared 関数の型は、shared 関数型を使って指定します。たとえば、`inc` の型は `shared () → async Nat` であり、他の Service への独立したコールバックとして渡すことができます (例として [publish-subscribe](sharing.md) を参照してください)。

## Actor 型

オブジェクトにオブジェクト型があるように、Actor には _Actor 型_ があります。`Counter` Actor は、以下の型を持っています。

```motoko no-repl
actor {
  inc  : shared () -> async ();
  read : shared () -> async Nat;
  bump : shared () -> async Nat;
}
```

繰り返しになりますが、`shared` 修飾子は Actor のすべてのメンバー関数に必要なので、Motoko では、表示時と Actor 型を書く際に記載を省略することができます。

よって、先述の型はより簡潔に表現すると次のようになります。

```motoko no-repl
actor {
  inc  : () -> async ();
  read : () -> async Nat;
  bump : () -> async Nat;
}
```

オブジェクト型と同様に、Actor 型も派生型をサポートしています。ある Actor 型は、より一般的な型を使っていて、関数の数がより少ない Actor の派生型となります。

## `await` を使って非同期の future を使用する

shared 関数の呼び出し側は、一般的には、ある T についての `async T` 型の値である future を受け取ります。

呼び出し側であるコンシューマ（受け取り側）がこの future に対してできることは、プロデューサ（future の生成側）の処理が完了するのを待つか、future を捨ててしまうか、後で使うために保存するかです。

`async` 値の結果にアクセスするには、future の受け取り側で `await` 式を使用します。

例えば、上述の `Counter.read()` の結果を利用するには、まず future を変数 `a` にバインドし、次に `await` で future 処理後の返り値となる `Nat` の `n` を取得します。

```motoko include=counter
let a : async Nat = Counter.read();
let n : Nat = await a;
```

1 行目はすぐに _カウンタ値の future_ を受け取りますが、処理の完了を待っていないため、自然数として使用することは（まだ）できません。

2 行目は、この future を `await` し、その結果を自然数で取り出します。 この行は、future の処理が完了するまで実行をブロッキングします。

一般的には、2 つのステップを 1 つにまとめ、非同期呼び出しを直接 `await` します。

```motoko include=counter
let n : Nat = await Counter.read();
```

呼び出し先が結果を返すまでブロッキングするローカル関数の呼び出しとは異なり、shared 関数の呼び出しは future である `f` をブロッキングせずにすぐに返します。 呼び出し時にブロッキングする代わりに、後で `await f` を呼び出すと、`f` が完了するまで現在の計算が中断されます。 呼び出し先によって future が完了すると、`await f` の実行はその結果とともに再開されます。 もし結果が値であれば、`await f` はその値を返します。 そうでなければ、結果は何らかのエラーであり、`await f` はそのエラーを `await f` の呼び出し側に伝播させます。

future を 2 回 await しても同じ結果になり、future に何らかのエラーが格納されている場合にはそのエラーが再びスローされます。 サスペンドは、future がすでに完了していても発生します。これによって、_それぞれの_ `await` の前に行われたステートの変更やメッセージ送信が確実にコミットされます。

:::danger

`await` を含まない関数はアトミックに実行されることが保証されています。具体的には、関数の実行中に環境が Actor のステートを変更することはできません。しかしながら、関数が `await` を実行すると、アトミック性は保証されなくなります。 `await` によって実行が一時停止され再開するまでの間、その Actor のステートは他の Actor からのメッセージの同時処理により変化する可能性があります。非同期の状態変化を防ぐのはプログラマの責任です。ただし、プログラマは `await` がコミットされる前に行われた状態変化に関しては、他の Actor からの干渉がないことを信じることができます。

:::

例えば上記の `bump()` の実装では、`count` の値を 1 つのアトミックなステップでインクリメントし、読み取ることが保証されています。 別の実装としては以下が考えられます。

```motoko no-repl
  public shared func bump() : async Nat {
    await inc();
    await read();
  };
```

これは上記の `bump()` の実装とは異なるセマンティクスとなり、Actor の別のクライアントが操作に干渉することを可能にします。それぞれの `await` は実行を一時停止するので、別の Actor がこの Actor のステートを関数の実行中に変更することが可能になります。 設計上、明示的な `await` は干渉の可能性があるポイントを、コードを読む人に対して明確にします。

## トラップとコミットポイント

トラップとは、ゼロ除算、範囲外への配列インデックス、数値のオーバーフロー、Cycle の枯渇、アサーションの失敗などが原因で発生する、回復不能なランタイムエラーのことです。

`await` 式を実行せずに実行される shared 関数の呼び出しは、サスペンドせずにアトミックに実行されます。`await` 式を含まない shared 関数は、構文的にアトミックです。

アトミックな shared 関数は、その実行時のトラップによって Actor のステートやその環境に目に見える影響を与えません。 すなわち、トラップされた場合にはステートの変化はすべて元に戻され、送信したメッセージはすべて破棄されます。 実際には、すべての状態変化とメッセージ送信は、実行中は暫定的なものであり、エラー無しに _コミットポイント_ に到達して初めてコミットされます。

暫定的な状態変化やメッセージ送信が取り消されずにコミットされるポイントは以下の通りです。

- 結果を生成することによる shared 関数の暗黙的な終了

- `return` や `throw` 式による明示的な終了

- 明示的な `await` 式

トラップが起こると、最後のコミットポイント以降に行われた変更のみが取り消されます。特に、複数の `await` を行う非アトミック関数では、トラップが起こると最後の `await` 以降に行われた変更のみが取り消され、その前のすべての副作用はコミットされてしまい、元に戻すことはできません。

例えば、次のような（作為的に）ステートフルな `Atomicity` Actor を考えてみましょう。

```motoko no-repl file=./examples/atomicity.mo

```

shared 関数である `atomic()` を呼び出すと、最後のステートメントがトラップを引き起こしてエラーとなります。しかし、このトラップによって、可変型変数 `s` の値は `1` ではなく `0` になり、変数 `pinged` の値は `true` ではなく `false` になります。これは、`atomic` メソッド が `await` を実行する前、あるいは結果の値を得て終了する前にトラップが発生しているためです。`atomic` が `ping()` を呼び出しても、`ping()` は次のコミットポイントまでの暫定的なもの (キューされたもの) なので、反映されることはありません。

shared 関数である `nonAtomic()` を呼び出すと、最後のステートメントがトラップを引き起こしてエラーとなります。しかし、このトラップによって、変数 `s` の値は `0` ではなく `3` になり、変数 `pinged` の値は `false` ではなく `true` になります。これは、各 `await` がメッセージ送信などの先行する副作用をコミットするためです。`f` に対する 2 回目の await で `f` が完了しても、この await はステートを強制的にコミットし、実行を一時停止して、この Actor への他のメッセージのインターリーブ処理が可能になります。

## クエリ関数

Internet Computer の用語では、3 つの `Counter` 関数はすべて _アップデート_ メッセージであり、関数が呼ばれると Canister のステートを変更することができます。 ステートを変更するには、Internet Computer が変更をコミットして結果を返す前に、分散したレプリカ間の合意が必要です。 コンセンサスを得るのは、比較的高いレイテンシを伴う高価なプロセスです。

コンセンサスの保証を必要としないアプリケーションの部分については、Internet Computer はより効率的であるクエリ操作をサポートしています。 これは、単一のレプリカから Canister のステートを読み取り、実行中にスナップショットを変更して結果を返すことができますが、ステートを恒久的に変更したり、さらなる Internet Computer のメッセージを送信することはできません。

Motoko は、`query` 関数を使用した Internet Computer のクエリの実装をサポートしています。`query` キーワードは shared Actor 関数の宣言を変更し、コミットせずに高速で実行されるクエリのセマンティクスになるようにします。

例えば、信頼性の高い `read` 関数をルーズにした `peek` 関数で `Counter` Actor を拡張してみましょう。

```motoko file=./examples/CounterWithQuery.mo

```

`peek()` 関数は、`Counter` フロントエンドで現在のカウンタの値を素早く（ただし信頼性低く）表示するのに使用される可能性があります。

クエリメソッドが Actor の関数を呼び出すことは、Internet Computer が課す動的な制限に違反するため、コンパイルエラーとなります。通常の関数への呼び出しは許可されています。

クエリ関数は、非クエリ関数から呼び出すことができます。 これらのネストされた呼び出しにはコンセンサスが必要なため、ネストされたクエリコールの効率化は期待できないでしょう。

`query` 修飾子はクエリ関数の型に反映されます。

```motoko no-repl
  peek : shared query () -> async Nat
```

これまでと同様、`query` の宣言や Actor 型では、`shared` キーワードを省略することができます。

## メッセージングの制限

Internet Computer は、Canister がいつどのように通信可能かについて制限を設けています。これらの制限は Internet Computer 上では動的に実施されますが、Motoko では静的に防止されるため、動的実行エラーの類を排除します。2 つの例は以下の通りです。

- Canister の設置時はコードを実行できますが、メッセージを送信できません。

- Canister のクエリメソッドはメッセージを送信できません。

これらの制限は、Motoko ではどの式を使用できるかというコンテキストの制限として表れています。

Motoko では、（shared またはローカルの関数のボディ内や独立した式として登場する）`async` 式のボディ内に式が登場するとき、_非同期コンテキスト_ になります。 唯一の例外は `query` 関数で、そのボディ内は非同期コンテキストとは見なされません。

Motoko では、shared 関数を呼び出すと、その関数が非同期コンテキストで呼び出されない限りエラーになります。また、Actor クラスのコンストラクタから shared 関数を呼び出してもエラーになります。

`await` 構文は非同期コンテキストでのみ使用できます。

`async` 構文は非同期コンテキストでのみ使用できます。

非同期コンテキストでは、エラーを `throw` または `try/catch` することしかできません。 これは、構造化されたエラー処理がメッセージングエラーに対してのみサポートされており、メッセージングそのものと同様、非同期コンテキストに限定されているためです。

これらのルールは、ローカル関数は一般的に shared 関数を直接呼び出したり、future を `await` することができないことを意味します。この制限は時に厄介なものです。将来的には型システムを拡張することで、より寛容にしたいと考えています。

## Actor クラスによる Actor の一般化

Actor _クラス_ は、単一の Actor 宣言を、同じインターフェイスを満たす Actor 群の宣言に一般化します。 Actor クラスは、Actor のインターフェイスを指定する型と、引数が与えられるたびにその型の新たな Actor を構築する関数を宣言します。 Actor クラスは、Actor を製造するファクトリーの役割を果たします。 Canister の設置は Internet Computer では非同期なので、コンストラクタ関数も非同期であり、Actor を future で返します。

例えば、コンストラクタのパラメータとして、`Nat` 型の変数 `init` を導入することで、上で与えられた `Counter` を以下の `Counter(init)` に一般化することができます。

`Counters.mo`:

```motoko name=Counters file=./examples/Counters.mo

```

このクラスが `Counters.mo` というファイルに格納されている場合には、ファイルをモジュールとしてインポートし、それを使って初期値の異なる複数のアクターを作ることができます。

```motoko include=Counters
import Counters "Counters";

let C1 = await Counters.Counter(1);
let C2 = await Counters.Counter(2);
(await C1.read(), await C2.read())
```

上の最後の 2 行は、Actor クラスを 2 回 _インスタンス化_ しています。 最初の呼び出しでは初期値 `1` を使用し、2 回目の呼び出しでは初期値 `2` を使用します。 Actor クラスのインスタンス化は非同期的なので、`Counter(init)` の各呼び出しは future を返し、結果として得られる Actor の値を `await` することができます。 `C1` と `C2` はどちらも同じ `Counters.Counter` 型であり、互換性を持って使用することができます。

:::note

現在のところ、Motoko コンパイラは、単一の Actor または Actor クラスで構成されていないプログラムをコンパイルするとエラーになります。 しかし、コンパイルされたプログラムは、インポートされた Actor クラスを参照することができます。 詳しくは [Actor クラスのインポート](modules-and-imports.md#importing_actor_classes) と [Actor クラス](actor-classes.md#actor_classes) を参照してください。

:::

<!--

# Actors and async data

The programming model of the Internet Computer consists of memory-isolated canisters communicating by asynchronous message passing of binary data encoding Candid values. A canister processes its messages one-at-a-time, preventing race conditions. A canister uses call-backs to register what needs to be done with the result of any inter-canister messages it issues.

Motoko abstracts the complexity of the Internet Computer with a well known, higher-level abstraction: the *actor model*. Each canister is represented as a typed actor. The type of an actor lists the messages it can handle. Each message is abstracted as a typed, asynchronous function. A translation from actor types to Candid types imposes structure on the raw binary data of the underlying Internet Computer. An actor is similar to an object, but is different in that its state is completely isolated, its interactions with the world are entirely through asynchronous messaging, and its messages are processed one-at-a-time, even when issued in parallel by concurrent actors.

In Motoko, sending a message to an actor is a function call, but instead of blocking the caller until the call has returned, the message is enqueued on the callee, and a *future* representing that pending request immediately returned to the caller. The future is a placeholder for the eventual result of the request, that the caller can later query. Between issuing the request, and deciding to wait for the result, the caller is free to do other work, including issuing more requests to the same or other actors. Once the callee has processed the request, the future is completed and its result made available to the caller. If the caller is waiting on the future, its execution can resume with the result, otherwise the result is simply stored in the future for later use.

In Motoko, actors have dedicated syntax and types; messaging is handled by so called *shared* functions returning futures (shared because they are available to remote actors); a future, `f`, is a value of the special type `async T` for some type `T`; waiting on `f` to be completed is expressed using `await f` to obtain a value of type `T`. To avoid introducing shared state through messaging, for example, by sending an object or mutable array, the data that can be transmitted through shared functions is restricted to immutable, *shared* types.

To start, we consider the simplest stateful service: a `Counter` actor, the distributed version of our previous, local `counter` object.

## Example: a Counter service

Consider the following actor declaration:

``` motoko file=./examples/counter-actor.mo
```

-->
<!--
actor Counter {

  var count = 0;

  public shared func inc() : async () { count += 1 };

  public shared func read() : async Nat { count };

  public shared func bump() : async Nat {
    count += 1;
    count;
  };
};
-->
<!--

The `Counter` actor declares one field and three public, *shared* functions:

-   the field `count` is mutable, initialized to zero and implicitly `private`.

-   function `inc()` asynchronously increments the counter and returns a future of type `async ()` for synchronization.

-   function `read()` asynchronously reads the counter value and returns a future of type `async Nat` containing its value.

-   function `bump()` asynchronously increments and reads the counter.

Shared functions, unlike local functions, are accessible to remote callers and have additional restrictions: their arguments and return value must be *shared* types - a subset of types that includes immutable data, actor references, and shared function references, but excludes references to local functions and mutable data. Because all interaction with actors is asynchronous, an actor’s functions must return futures, that is, types of the form `async T`, for some type `T`.

The only way to read or modify the state (`count`) of the `Counter` actor is through its shared functions.

A value of type `async T` is a future. The producer of the future completes the future when it returns a result, either a value or error.

Unlike objects and modules, actors can only expose functions, and these functions must be `shared`. For this reason, Motoko allows you to omit the `shared` modifier on public actor functions, allowing the more concise, but equivalent, actor declaration:

``` motoko name=counter file=./examples/counter-actor-sugar.mo
```

For now, the only place shared functions can be declared is in the body of an actor or actor class. Despite this restriction, shared functions are still first-class values in Motoko and can be passed as arguments or results, and stored in data structures.

The type of a shared function is specified using a shared function type. For example, the value `inc` has type `shared () → async Nat` and could be supplied as a standalone callback to some other service (see [publish-subscribe](sharing.md) for an example).

## Actor types

Just as objects have object types, actors have *actor types*. The `Counter` actor has the following type:

``` motoko no-repl
actor {
  inc  : shared () -> async ();
  read : shared () -> async Nat;
  bump : shared () -> async Nat;
}
```

Again, because the `shared` modifier is required on every member of an actor, Motoko both elides them on display, and allows you to omit them when authoring an actor type.

Thus the previous type can be expressed more succinctly as:

``` motoko no-repl
actor {
  inc  : () -> async ();
  read : () -> async Nat;
  bump : () -> async Nat;
}
```

Like object types, actor types support subtyping: an actor type is a subtype of a more general one that offers fewer functions with more general types.

## Using `await` to consume async futures

The caller of a shared function typically receives a future, a value of type `async T` for some T.

The only thing the caller, a consumer, can do with this future is wait for it to be completed by the producer, throw it away, or store it for later use.

To access the result of an `async` value, the receiver of the future use an `await` expression.

For example, to use the result of `Counter.read()` above, we can first bind the future to an identifier `a`, and then `await a` to retrieve the underlying `Nat`, `n`:

``` motoko include=counter
let a : async Nat = Counter.read();
let n : Nat = await a;
```

The first line immediately receives *a future of the counter value*, but does not wait for it, and thus cannot (yet) use it as a natural number.

The second line `await`s this future and extracts the result, a natural number. This line may suspend execution until the future has been completed.

Typically, one rolls the two steps into one and one just awaits an asynchronous call directly:

``` motoko include=counter
let n : Nat = await Counter.read();
```

Unlike a local function call, which blocks the caller until the callee has returned a result, a shared function call immediately returns a future, `f`, without blocking. Instead of blocking, a later call to `await f` suspends the current computation until `f` is complete. Once the future is completed (by the producer), execution of `await p` resumes with its result. If the result is a value, `await f` returns that value. Otherwise the result is some error, and `await f` propagates the error to the consumer of `await f`.

Awaiting a future a second time will just produce the same result, including re-throwing any error stored in the future. Suspension occurs even if the future is already complete; this ensures state changes and message sends prior to *every* `await` are committed.

:::danger

A function that does not `await` in its body is guaranteed to execute atomically - in particular, the environment cannot change the state of the actor while the function is executing. If a function performs an `await`, however, atomicity is no longer guaranteed. Between suspension and resumption around the `await`, the state of the enclosing actor may change due to concurrent processing of other incoming actor messages. It is the programmer’s responsibility to guard against non-synchronized state changes. A programmer may, however, rely on any state change prior to the await being committed.

:::

For example, the implementation of `bump()` above is guaranteed to increment and read the value of `count`, in one atomic step. The alternative implementation:

``` motoko no-repl
  public shared func bump() : async Nat {
    await inc();
    await read();
  };
```

does *not* have the same semantics and allows another client of the actor to interfere with its operation: each `await` suspends execution, allowing an interloper to change the state of the actor. By design, the explicit `await`s make the potential points of interference clear to the reader.

## Traps and Commit Points

A trap is a non-recoverable runtime failure caused by, for example, division-by-zero, out-of-bounds array indexing, numeric overflow, cycle exhaustion or assertion failure.

A shared function call that executes without executing an `await` expression never suspends and executes atomically. A shared function that contains no `await` expression is syntactically atomic.

An atomic shared function whose execution traps has no visible effect on the state of the enclosing actor or its environment - any state change is reverted, and any message that it has sent is revoked. In fact, all state changes and message sends are tentative during execution: they are committed only after a successful *commit point* is reached.

The points at which tentative state changes and message sends are irrevocably committed are:

-   implicit exit from a shared function by producing a result,

-   explict exit via `return` or `throw` expressions, and

-   explicit `await` expressions.

A trap will only revoke changes made since the last commit point. In particular, in a non-atomic function that does multiple awaits, a trap will only revoke changes attempted since the last await - all preceding effects will have been committed and cannot be undone.

For example, consider the following (contrived) stateful `Atomicity` actor:

``` motoko no-repl file=./examples/atomicity.mo
```

Calling (shared) function `atomic()` will fail with an error, since the last statement causes a trap. However, the trap leaves the mutable variable `s` with value `0`, not `1`, and variable `pinged` with value `false`, not `true`. This is because the trap happens *before* method `atomic` has executed an `await`, or exited with a result. Even though `atomic` calls `ping()`, `ping()` is tentative (queued) until the next commit point, so never delivered.

Calling (shared) function `nonAtomic()` will fail with an error, since the last statement causes a trap. However, the trap leaves the variable `s` with value `3`, not `0`, and variable `pinged` with value `true`, not `false`. This is because each `await` commits its preceding side-effects, including message sends. Even though `f` is complete by the second await on `f`, this await also forces a commit of the state, suspends execution and allows for interleaved processing of other messages to this actor.

## Query functions

In Internet Computer terminology, all three `Counter` functions are *update* messages that can alter the state of the canister when called. Effecting a state change requires agreement amongst the distributed replicas before the Internet Computer can commit the change and return a result. Reaching consensus is an expensive process with relatively high latency.

For the parts of applications that don’t require the guarantees of consensus, the Internet Computer supports more efficient *query* operations. These are able to read the state of a canister from a single replica, modify a snapshot during their execution and return a result, but cannot permanently alter the state or send further Internet Computer messages.

Motoko supports the implementation of Internet Computer queries using `query` functions. The `query` keyword modifies the declaration of a (shared) actor function so that it executes with non-committing, and faster, Internet Computer query semantics.

For example, we can extend the `Counter` actor with a fast-and-loose variant of the trustworthy `read` function, called `peek`:

``` motoko file=./examples/CounterWithQuery.mo
```

The `peek()` function might be used by a `Counter` frontend offering a quick, but less trustworthy, display of the current counter value.

It is a compile-time error for a query method to call an actor function since this would violate dynamic restrictions imposed by the Internet Computer. Calls to ordinary functions are permitted.

Query functions can be called from non-query functions. Because those nested calls require consensus, the efficiency gains of nested query calls will be modest at best.

The `query` modifier is reflected in the type of a query function:

``` motoko no-repl
  peek : shared query () -> async Nat
```

As before, in `query` declarations and actor types the `shared` keyword can be omitted.

## Messaging Restrictions

The Internet Computer places restrictions on when and how canisters are allowed to communicate. These restrictions are enforced dynamically on the Internet Computer but prevented statically in Motoko, ruling out a class of dynamic execution errors. Two examples are:

-   canister installation can execute code, but not send messages.

-   a canister query method cannot send messages.

These restrictions are surfaced in Motoko as restrictions on the context in which certain expressions can be used.

In Motoko, an expression occurs in an *asynchronous context* if it appears in the body of an `async` expression, which may be the body of a (shared or local) function or a stand-alone expression. The only exception are `query` functions, whose body is not considered to open an asynchronous context.

In Motoko calling a shared function is an error unless the function is called in an asynchronouus context. In addition, calling a shared function from an actor class constructor is also an error.

The `await` construct is only allowed in an asynchronous context.

The `async` construct is only allowed in an asynchronous context.

It is only possible to `throw` or `try/catch` errors in an asynchronous context. This is because structured error handling is supported for messaging errors only and, like messaging itself, confined to asynchronous contexts.

These rules also mean that local functions cannot, in general, directly call shared functions or `await` futures. This limitation can sometimes be awkward: we hope to extend the type system to be more permissive in future.

-->
<!--
TODO: scoped awaits (if at all)
-->
<!--

## Actor classes generalize actors

An actor *class* generalizes a single actor declaration to the declaration of family of actors satisfying the same interface. An actor class declares a type, naming the interface of its actors, and a function that constructs a fresh actor of that type each time it is supplied with an argument. An actor class thus serves as a factory for manufacturing actors. Because canister installation is asynchronous on the Internet Computer, the constructor function is asynchronous too, and returns its actor in a future.

For example, we can generalize `Counter` given above to `Counter(init)` below, by introducing a constructor parameter, variable `init` of type `Nat`:

`Counters.mo`:

``` motoko name=Counters file=./examples/Counters.mo
```

If this class is stored in file `Counters.mo`, then we can import the file as a module and use it to create several actors with different initial values:

``` motoko include=Counters
import Counters "Counters";

let C1 = await Counters.Counter(1);
let C2 = await Counters.Counter(2);
(await C1.read(), await C2.read())
```

The last two lines above *instantiate* the actor class twice. The first invocation uses the initial value `1`, where the second uses initial value `2`. Because actor class instantiation is asynchronous, each call to `Counter(init)` returns a future that can be `await`ed for the resulting actor value. Both `C1` and `C2` have the same type, `Counters.Counter` and can be used interchangeably.

:::note

For now, the Motoko compiler gives an error when compiling programs that do not consist of a single actor or actor class. Compiled programs may still, however, reference imported actor classes. For more information, see [Importing actor classes](modules-and-imports.md#importing-actor-classes) and [Actor classes](actor-classes.md#actor-classes).

:::

-->
