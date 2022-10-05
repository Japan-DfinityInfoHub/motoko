# Cycle を管理する

Internet Computer の使用量は Cycle によって計測され、Cycle によって支払われます。 Internet Computer は Canister スマートコントラクトごとに Cycle の残高を保持します。 さらに、Cycle は Canister 間で転送することが可能です。

Internet Computer を対象とする Motoko プログラムでは、各 Actor は Internet Computer の Canister を表し、関連する Cycle の残高を保持します。 Cycle の所有権は Actor 間で移動することができます。 Cycle はメッセージ、つまり shared 関数の呼び出しによって選択的に送受信されます。 呼び出し元（Caller）は関数呼び出しで Cycle を転送することを選択でき、呼び出し先（Callee）は Cycle を受け入れることを選択できます。 明示的に指示されない限り、呼び出し元からの Cycle の転送や呼び出し先の Cycle の受け入れは行われません。

呼び出し先は、利用可能な Cycle の全てまたは一部を受け取るか、一切受け取らないかを選択することができます。受け取りの上限値は、Actor の現在の残高によって決まります。 Cycle が余った場合、残りの Cycle は呼び出し元に返金されます。 呼び出しがトラップされた場合、それに付随するすべての Cycle は、失われることなく自動的に呼び出し元に返金されます。

将来的には、Motoko が Cycle を用いた安全なプログラミングをサポートする専用の構文と型を採用する可能性があります。 現在のところ、Cycle を管理するための一時的な方法を、`base` パッケージ内の低レベルな命令型 API である [ExperimentalCycles](./base/ExperimentalCycles.md) ライブラリ を通して提供しています。

:::note

このライブラリは変更される可能性があり、Motoko の後のバージョンでは、Cycle のより高レベルなサポートに置き換えられると考えられます。

:::

## `ExperimentalCycles` ライブラリ

`ExperimentalCycles` ライブラリは、Actor の現在の Cycle 残高の確認、転送、払い戻しの確認に関する命令的な操作を提供します。

このライブラリは以下の操作を提供します。

```motoko no-repl
func balance() : (amount : Nat)

func available() : (amount : Nat)

func accept(amount : Nat) : (accepted : Nat)

func add(amount : Nat) : ()

func refunded() : (amount : Nat)
```

`balance()` 関数は、Actor の現在の Cycle 残高を `amount` として返します。 `balance()` 関数はステートフル（stateful）であり、`accept(n)` の呼び出し後や、Cycle を `add` した後の関数呼び出し、（払い戻しを反映させて）await から再開したりした後では異なる値を返す可能性があります。

:::danger

Cycle は消費された計算リソースを測定するものであるため、`balance()` の値は一般的に shared 関数を呼び出すたびに減少します。

:::

`available()` 関数は、現在利用可能な Cycle の量（`amount`）を返します。 これは、呼び出し元から送られた金額から、これまでに受け入れられた（`accept` された）累積金額を差し引いたものです。 現在の shared 関数や `async` 式から `return` や `throw` によって抜けると、残りの利用可能量は呼び出し元に自動的に払い戻されます。

`accept` 関数は `available()` から `balance()` へ `amount` を転送します。 この関数は実際に転送された Cycle の量を返します。例えば、利用可能な量が少なかったり、Canister の残高制限に達している場合には、要求された量よりも少なくなることがあります。

`add(amount)` 関数は、次のリモートコール（shared 関数呼び出しまたは `async` 式の評価）で転送される Cycle の追加量を指定します。 その際、最後の呼び出しから `add` された総 Cycle 量が `balance()` から（呼び出し前でなく呼び出し時に）差し引かれます。 この合計が `balance()` を超える場合、呼び出し元はトラップして呼び出しを中止します。

:::note

追加される Cycle 量は暗黙的に記録されます。各 `add` でインクリメントされ、 shared 関数のコールの後また await から再開されたときに、ゼロにリセットされます。

:::

`refunded()` 関数は、現在のコンテキストにおける最後の `await` で払い戻された Cycle の `amount` をレポートします。ただし、まだ await が発生していない場合はゼロをレポートします。`refunded()` の呼び出しは情報を得るのみで、`balance()` には影響を与えません。 その代わり、`refunded` 関数が払い戻しを監視するために使用されたかどうかに関わらず、払い戻しは自動的に現在の残高に追加されます。

### 例

理解を深めるため、`ExperimentalCycles` ライブラリを使用して、Cycle を保存するためのおもちゃの _貯金箱（piggy bank）_ を実装してみましょう。

この貯金箱には暗黙の所有者、`benefit` というコールバック関数、固定値である限度額（`capacity`）があり、これらはすべてコンストラクタが呼び出されたときに提供されます。 コールバック関数は _引き出される（withdrawn）_ 量を転送するために使用されます。

```motoko name=PiggyBank file=./examples/PiggyBank.mo

```

貯金箱の所有者はコンストラクタ `PiggyBank()` の呼び出し元と（暗黙的に）なり、共有パターンである `shared(msg)` を用いて識別されます。 `msg.caller` フィールドは `Principal` で、プライベート変数である `owner` に格納されます（将来の参照用）。 この構文についての詳しい説明は [プリンシパルと Caller の識別](caller-id.md)を参照してください。

貯金箱は初期状態では空っぽで、これは `savings` の現在の値がゼロであることで表現されます。

所有者（`owner`）からの呼び出しのみが可能で、以下のような操作を行うことができます。

- 貯金箱の現在の貯金額（`savings`）を問い合わせる (`getSavings()` 関数)。

- 貯金箱からお金を引き出す（`withdraw(amount)` 関数）。

呼び出し元の制限は、`assert (msg.caller == owner)` という文（statement）によって強制されます。 失敗すると関数がトラップされ、残高を明らかにしたり、Cycle を移動させることはできせん。

どの呼び出し元も、任意の量の Cycle を貯金（`deposit`）することができ、貯金額が限度額（`capacity`）を超えて貯金箱を壊すことはありません。 入金機能は利用可能（available）な金額の一部しか受け付けないため、入金額が上限を超えた呼び出し元は、受け付けられなかった Cycle の払い戻しを暗黙のうちに受けることになります。 払い戻しは自動的に行われ、Internet Computer 基盤によって保証されます。

Cycle の転送は一方向（呼び出し元（Caller）から呼び出し先（Callee））であるため、Cycle を取得するためには、明示的なコールバック（コンストラクタが引数として受け取る `benefit` 関数）が必要になります。 ここでは、呼び出し元が `owner` であることを認証した後に、`benefit` が `withdraw` 関数によって呼び出されます。 `withdraw` の中で `benefit` を呼び出すと、呼び出し元と呼び出し先の関係が反転し、Cycle が "上流（upstream）" に流れるようになります。

`PiggyBank` の所有者は、実際には `owner` とは別の者に報酬を与えるようなコールバックを提供することができることに注意してください。

以下は、ある所有者 `Alice` が `PiggyBank` のインスタンスをどのように使用するかを示しています。

```motoko include=PiggyBank file=./examples/Alice.mo

```

`Alice` のコードを詳しく見てみましょう。

`Alice` は新しい `PiggyBank` Actor を必要に応じて作成できるように、`PiggyBank` という Actor クラスをライブラリとしてインポートしています。

ほとんどの動作は `Alice` の `test()` 関数で発生します。

`PiggyBank` の新しいインスタンスである `porky` を作成する直前に、Alice は貯金箱を動かすために彼女の 10_000_000_000_000 Cycles を使って `Cycles.add(10_000_000_000_000)` を呼び出しています。 インスタンス生成時に、Alice はコールバック関数である `Alice.credit` と、貯金箱の上限額（`10_000_000_000_000`）を渡しています。 `Alice.credit` を渡すことで、引出しの受益者として `Alice` を指定しています。 `10_000_000_000_000` から少額のインストール費用を差し引いた Cycle が、初期化コードによる追加操作なしに `porky` の残高に振り込まれます。 これは、使用するたびに自分自身のリソースを消費する、電子的な貯金箱のようなものと考えることができます。 `PiggyBank` のコンストラクタの呼び出しは非同期なので、`Alice` はその結果を `await` する必要があります。

`porky` を作成した後、Alice は最初に `assert` を使って `porky.getSavings()` がゼロであることを検証しています。

`Alice` は次の `porky.deposit()` の呼び出しで `porky` に Cycle を転送するため、自分の Cycle のうち `1_000_000` を充当しています（`Cycles.add(1_000_000)`）。 Cycle は `porky.deposit()` のコールが成功した場合のみ（するはずです）、Alice の残高から消費されます。

`Alice` は次に、先ほど充当した量の半分である `500_000` を引き出し、`porky` の貯蓄が半分になったことを検証します。 `Alice` は `porky.withdraw()` で実行される `Alice.credit()` のコールバックを介して最終的に Cycle を受け取ります。 なお、`porky.withdraw()` で `benefit` コールバック（ここでは `Alice.credit`）を実行する前に `add` された Cycle を受け取っていることに注意してください。

`Alice` はさらに `500_000` Cycle 分引き出し、貯金を使い果たします。

次に `Alice` はむだに `2_000_000` Cycle を `porky` に預けようとしますが、これは `porky` の上限を上回るため、`porky` は `1_000_000_000` を受け取り、残りの `1_000_000_000` を `Alice` に払い戻します。 `Alice` は（すでに）自動的に残高に戻された返金額を検証しています（`Cycles.refunded()`）。 また、`Alice` は `porky` の調整後の残高も検証しています。

`Alice` の `credit()` 関数は `Cycles.accept(available)` を呼び出すことで、利用可能なすべての Cycle を単に受け取り、実際に受け取った（`accepted`）額を assert でチェックしています。

:::note

この例では、Alice はすでに所有している（すぐに使える）Cycle を使用しています。

:::

:::danger

`porky` は動作に Cycle を消費するため、Alice が回収する前に貯蓄したサイクルの一部あるいは全部を、`porky` が使う可能性があります。

:::

<!--
# Managing cycles

Usage of the Internet Computer is measured, and paid for, in *cycles*. The Internet Computer maintains a balance of cycles per canister smart contract. In addition, cycles can be transferred between canisters.

In Motoko programs targeting the Internet Computer, each actor represents an Internet Computer canister, and has an associated balance of cycles. The ownership of cycles can be transferred between actors. Cycles are selectively sent and received through messages, that is, shared function calls. A caller can choose to transfer cycles with a call, and a callee can choose to accept cycles that are made available by the caller. Unless explicitly instructed, no cycles are transferred by callers or accepted by callees.

Callees can accept all, some or none of the available cycles up to limit determined by their actor’s current balance. Any remaining cycles are refunded to the caller. If a call traps, all its accompanying cycles are automatically refunded to the caller, without loss.

In future, we may see Motoko adopt dedicated syntax and types to support safer programming with cycles. For now, we provide a temporary way to manage cycles through a low-level imperative API provided by the [ExperimentalCycles](./base/ExperimentalCycles.md) library in package `base`.

:::note

This library is subject to change and likely to be replaced by more high-level support for cycles in later versions of Motoko.

:::

## The `ExperimentalCycles` Library

The `ExperimentalCycles` library provides imperative operations for observing an actor’s current balance of cycles, transferring cycles and observing refunds.

The library provides the following operations:

``` motoko no-repl
func balance() : (amount : Nat)

func available() : (amount : Nat)

func accept(amount : Nat) : (accepted : Nat)

func add(amount : Nat) : ()

func refunded() : (amount : Nat)
```

Function `balance()` returns the actor’s current balance of cycles as `amount`. Function `balance()` is stateful and may return different values after calls to `accept(n)`, calling a function after `add`ing cycles, or resuming from await (reflecting a refund).

:::danger

Since cycles measure computational resources spent, the value of `balance()` generally decreases from one shared function call to the next.

:::

Function `available()`, returns the currently available `amount` of cycles. This is the amount received from the current caller, minus the cumulative amount `accept`ed so far by this call. On exit from the current shared function or `async` expression via `return` or `throw` any remaining available amount is automatically refunded to the caller.

Function `accept` transfers `amount` from `available()` to `balance()`. It returns the amount actually transferred, which may be less than requested, for example, if less is available, or if canister balance limits are reached.

Function `add(amount)` indicates the additional amount of cycles to be transferred in the next remote call, i.e. evaluation of a shared function call or `async` expression. Upon the call, but not before, the total amount of units `add`ed since the last call is deducted from `balance()`. If this total exceeds `balance()`, the caller traps, aborting the call.

:::note

the implicit register of added amounts, incremented on each `add`, is reset to zero on entry to a shared function, and after each shared function call or on resume from an await.

:::

Function `refunded()` reports the `amount` of cycles refunded in the last `await` of the current context, or zero if no await has occurred yet. Calling `refunded()` is solely informational and does not affect `balance()`. Instead, refunds are automatically added to the current balance, whether or not `refunded` is used to observe them.

### Example

To illustrate, we will now use the `ExperimentalCycles` library to implement a toy *piggy bank* for saving cycles.

Our piggy bank has an implicit owner, a `benefit` callback and a fixed `capacity`, all supplied at time of construction. The callback is used to transfer *withdrawn* amounts.

``` motoko name=PiggyBank file=./examples/PiggyBank.mo
```

The owner of the bank is identified with the (implicit) caller of constructor `PiggyBank()`, using the shared pattern, `shared(msg)`. Field `msg.caller` is a `Principal` and is stored in private variable `owner` (for future reference). See [Principals and caller identification](caller-id.md) for more explanation of this syntax.

The piggy bank is initially empty, with zero current `savings`.

Only calls from `owner` may:

-   query the current `savings` of the piggy bank (function `getSavings()`), or

-   withdraw amounts from the savings (function `withdraw(amount)`).

The restriction on the caller is enforced by the statements `assert (msg.caller ==
owner)`, whose failure causes the enclosing function to trap, without revealing the balance or moving any cycles.

Any caller may `deposit` an amount of cycles, provided the savings will not exceed `capacity`, breaking the piggy bank. Because the deposit function only accepts a portion of the available amount, a caller whose deposit exceeds the limit will receive an implicit refund of any unaccepted cycles. Refunds are automatic and ensured by the Internet Computer infrastructure.

Since transfer of cycles is one-directional (from caller to callee), retrieving cycles requires the use of an explicit callback (the `benefit` function, taken by the constructor as an argument). Here, `benefit` is called by the `withdraw` function, but only after authenticating the caller as `owner`. Invoking `benefit` in `withdraw` inverts the caller/caller relationship, allowing cycles to flow "upstream".

Note that the owner of the `PiggyBank` could, in fact, supply a callback that rewards a beneficiary distinct from `owner`.

Here’s how an owner, `Alice`, might use an instance of `PiggyBank`:

``` motoko include=PiggyBank file=./examples/Alice.mo
```

Let’s dissect `Alice`'s code.

`Alice` imports the `PiggyBank` actor class as a library, so she can create a new `PiggyBank` actor on demand.

Most of the action occurs in `Alice`'s `test()` function:

Alice dedicates `10_000_000_000_000` of her own cycles for running the piggy bank, by calling `Cycles.add(10_000_000_000_000)` just before creating a new instance, `porky`, of the `PiggyBank`, passing callback `Alice.credit` and capacity (`1_000_000_000`). Passing `Alice.credit` nominates `Alice` as the beneficiary of withdrawals. The `10_000_000_000_000` cycles, minus a small installation fee, are credited to `porky`'s balance without any further action by `porky` initialization code. You can think of this as an electric piggy bank, that consumes its own resources as its used. Since constructing a `PiggyBank` is asynchronous, `Alice` needs to `await` the result.

After creating `porky`, she first verifies that the `porky.getSavings()` is zero using an `assert`.

`Alice` dedicates `1_000_000` of her cycles (`Cycles.add(1_000_000)`) to transfer to `porky` with the next call to `porky.deposit()`. The cycles are only consumed from Alice’s balance if the call to `porky.deposit()` succeeds (which it should).

`Alice` now withdraws half the amount, `500_000`, and verifies that `porky`'s savings have halved. `Alice` eventually receives the cycles via a callback to `Alice.credit()`, initiated in `porky.withdraw()`. Note the received cycles are precisely the cycles `add`ed in `porky.withdraw()`, before it invokes its `benefit` callback, that is, `Alice.credit`.

`Alice` withdraws another `500_000` cycles to wipe out her savings.

`Alice` vainly tries to deposit `2_000_000_000` cycles into `porky` but this exceeds `porky`'s capacity by half, so `porky` accepts `1_000_000_000` and refunds the remaining `1_000_000_000` to `Alice`. `Alice` verifies the refund amount (`Cycles.refunded()`), which has (already) been automatically restored to her balance. She also verifies `porky`'s adjusted savings.

`Alice`'s `credit()` function simply accepts all available cycles by calling `Cycles.accept(available)`, checking the actually `accepted` amount with an assert.

:::note

For this example, Alice is using her (readily available) cycles, that she already owns.

:::

:::danger

Because `porky` consumes cycles in its operation, it is possible for `porky` to spend some or even all of Alice’s cycle savings before she has a chance to retrieve them.

:::

-->
