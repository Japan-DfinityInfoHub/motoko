# プリンシパルと Caller の識別

Motoko の Shared 関数は、シンプルな Caller（関数の呼び出し元）の識別（Identification）をサポートしており、これにより関数の Caller に関連付けられた Internet Computer の **プリンシパル** を検査することが可能になります。 関数の呼び出しに関連づけられたプリンシパルは、ユニークなユーザか Canister スマートコントラクトを識別する値です。

関数の Caller に関連づけられたプリンシパルを用いて、プログラム内で基本的な形式の _アクセスコントロール_ を実装することができます。

Motoko では、`shared` キーワードを用いて `Shared` 関数を宣言します。 また、Shared 関数は `{caller : Principal}` 型のオプション引数を宣言することができます。

Shared 関数の Caller にアクセスする方法を説明するため、以下のような関数を考えます：

```motoko
shared(msg) func inc() : async () {
  // ... msg.caller ...
}
```

この例では、Shared 関数である `inc()` は Record 型である `msg` を受け取り、`msg.caller` は `msg` のプリンシパルフィールドにアクセスします。

`inc()` 関数の呼び出しは変更されません。それぞれの関数呼び出しにおいて、呼び出し側のプリンシパルはユーザーではなくシステムから提供されます。そのため、悪意のあるユーザーはプリンシパルを偽造したり、なりすましたりすることができません。

Actor クラスのコンストラクタの Caller にアクセスするには、Actor クラスの宣言と同じ（オプショナルの）シンタックスを用います。 例えば、以下のようになります：

```motoko
shared(msg) actor class Counter(init : Nat) {
  // ... msg.caller ...
}
```

この例を拡張し、`Counter` のインストーラであるプリンシパルだけが `Counter` を変更できるように制限したいとします。 これを行うには、Actor を設置したプリンシパルを `owner` 変数にバインドして記録します。 そうすることで、各メソッドの呼び出し元が `owner` と等しいかどうかを次のようにチェックすることができます：

```motoko file=./examples/Counters-caller.mo

```

この例では、`assert (owner == msg.caller)` により、関数 `inc()` と `bump()` の呼び出しが認証されていなければトラップし、`count` 変数の変更を阻止します。一方、`read()` 関数はあらゆる呼び出しを許可しています。

また、`shared` の引数は単なるパターンなので、お好みで、上記をパターンマッチを使うように書き換えることもできます:

```motoko file=./examples/Counters-caller-pat.mo

```

:::note

単純な Actor 宣言では、そのインストーラにアクセスすることはできません。Actor のインストーラにアクセスする必要がある場合は、Actor 宣言を引数なしの Actor クラスに書き換えてください。

:::

プリンシパルは等価性、順序付け、ハッシングをサポートしているため、コンテナにプリンシパルを効率的に格納して、許可リストや拒否リストを管理することができます。 プリンシパルに関するその他の操作は、[Principal](./base/Principal.md) 標準ライブラリを参照してください。

<!--
# Principals and caller identification

Motoko’s shared functions support a simple form of caller identification that allows you to inspect the Internet Computer **principal** associated with the caller of a function. The principal associated with a call is a value that identifies a unique user or canister smart contract.

You can use the **principal** associated with the caller of a function to implement a basic form of *access-control* in your program.

In Motoko, the `shared` keyword is used to declare a shared function. The shared function can also declare an optional parameter of type `{caller : Principal}`.

-->
<!--
(The type is a record to accommodate future extension.)
-->
<!--

To illustrate how to access the caller of a shared function, consider the following:

``` motoko
shared(msg) func inc() : async () {
  // ... msg.caller ...
}
```

In this example, the shared function `inc()` specifies a `msg` parameter, a record, and the `msg.caller` accesses the principal field of `msg`.

The calls to the `inc()` function do not change — at each call site, the caller’s principal is provided by the system, not the user — so the principal cannot be forged or spoofed by a malicious user.

To access the caller of an actor class constructor, you use the same (optional) syntax on the actor class declaration. For example:

``` motoko
shared(msg) actor class Counter(init : Nat) {
  // ... msg.caller ...
}
```

To extend this example, assume you want to restrict the `Counter` actor so it can only be modified by the installer of the `Counter`. To do this, you can record the principal that installed the actor by binding it to an `owner` variable. You can then check that the caller of each method is equal to `owner` like this:

``` motoko file=./examples/Counters-caller.mo
```

In this example, the `assert (owner == msg.caller)` expression causes the functions `inc()` and `bump()` to trap if the call is unauthorized, preventing any modification of the `count` variable while the `read()` function permits any caller.

The argument to `shared` is just a pattern, so, if you prefer, you can also rewrite the above to use pattern matching:

``` motoko file=./examples/Counters-caller-pat.mo
```

:::note

Simple actor declarations do not let you access their installer. If you need access to the installer of an actor, rewrite the actor declaration as a zero-argument actor class instead.

:::

Principals support equality, ordering, and hashing, so you can efficiently store principals in containers, for example, to maintain an allow or deny list. More operations on principals are available in [Principal](./base/Principal.md) base library.

-->
