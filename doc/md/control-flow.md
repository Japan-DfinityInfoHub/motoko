# 命令的な制御フロー

制御フローには 2 つの重要なカテゴリーがあります。

- `if` や `switch` 式のように、ある値の構造が、制御や次に評価する式の選択を促すとき、_宣言的_ 制御フローと呼ばれます。

- プログラマの命令に応じて制御が突然変更され、通常の制御フローを放棄するような場合、_命令的_ 制御フローと呼ばれます。例としては、`break` や `continue`、`return` や `throw` があります。

命令的な制御フローは、ステート変化やエラー処理や入出力などの副作用と密接に関係していることが多いです。

## 関数からの早期 `return`

通常、関数から返す値は関数本体の全体を評価した結果の値です。しかしながら、時には関数本体の評価の終了前に結果が得られることがあります。このような状況では、`return ⟨式⟩` 構文を使用し、残りの計算を放棄して結果を持って直ちに関数を終了することができます。 `throw` の使用が許可されている場合には、関数本体で `throw` を使用することで、エラーが発生したときに計算を放棄することができます。

関数の結果がユニット型の場合、`return ()` の代わりに、短縮形の `return` を使用することができます。

## ループとラベル

Motoko では、以下のような数種類の繰り返し構造が用意されています。

- 構造化されたデータのメンバを反復処理するための `for` 式。

- プログラムによる繰り返しのための `loop` 式（オプションで終了条件を与える）。

- プログラムによる繰り返しのための `while` ループ（入口に条件式を与える）。

これらはいずれも、ループにシンボリックな名前を付けるために、`label ⟨ラベル名⟩` という修飾子を前に付けることができます。名前付きループは、ループの入口に戻って処理を継続したり（continue）、ループ処理を中断（break）するように命令的に制御フローを変更するのに便利です。

- `continue ⟨ラベル名⟩` を使ってループの入口に戻るか、

- `break ⟨ラベル名⟩` を使ってループから抜ける

以下の例では、`for` 式はあるテキストの文字列に対してループし、文字が感嘆符の場合にすぐにイタレーションを破棄します。

```motoko
import Debug "mo:base/Debug";
label letters for (c in "ran!!dom".chars()) {
  Debug.print(debug_show(c));
  if (c == '!') { break letters };
  // ...
}
```

### ラベル付けされた式

`label` には他にも 2 つの側面があり、あまり主流ではありませんが、ある特定の状況では便利です。

- `label` は型付け可能です。

- （ループに限らず）_いかなる_ 式にも label を前に付けることで名前を付けることができます。`break` を指定すると、式の結果に即座に値を与えて、式の評価を短絡させることができます。（これは `return` を使って関数を早期に終了させるのと似ていますが、関数を宣言して呼び出すというオーバーヘッドがありません。）

型注釈されたラベルの構文は、`label ⟨ラベル名⟩ : ⟨型⟩ ⟨式⟩` となります。任意の式を `break ⟨ラベル名⟩ ⟨別の式⟩` 構造を使って終了し、 `⟨別の式⟩` の値を返して `⟨式⟩` の評価を短絡させることができます。

これらの構造をうまく使うことで、プログラマは主要なプログラムロジックに集中しつつ、`break` を使って例外的なケースを処理することができます。

```motoko
import Text "mo:base/Text";
import Iter "mo:base/Iter";

type Host = Text;
let formInput = "us@dfn";

let address = label exit : ?(Text, Host) {
  let splitted = Text.split(formInput, #char '@');
  let array = Iter.toArray<Text>(splitted);
  if (array.size() != 2) { break exit(null) };
  let account = array[0];
  let host = array[1];
  // if (not (parseHost(host))) { break exit(null) };
  ?(account, host)
}
```

当然ながら、ラベル付けされた普通の（ループではない）式では `continue` は使えません。型付けに関しては、`⟨式⟩` と `⟨別の式⟩` の両方の型がラベルが宣言した `⟨型⟩` と一致する必要があります。ラベルに `⟨ラベル名⟩` だけが与えられている場合、そのデフォルトの `⟨型⟩` はユニット型 (`()`) になっています。同様に、`⟨別の式⟩` のない `break` は unit (`()`) という値の略記となります。

## Option ブロックと null 値ブレーク

他の多くの高級言語と同様に、Motoko では `null` 値を使用することができ、`?T` 形式の Option 型を使って `null` 値が発生する可能性を追跡できます。 これは、可能な限り `null` 値を使用しないようにすることと、必要なときに `null` 値である可能性を考慮することの両方を目的としています。

もし `null` 値をテストする唯一の方法が冗長な `switch` 式なら後者は面倒だったかもしれませんが、Motoko では _Option ブロック_ や _null 値ブレーク_ といった専用の構文で Option 型の取り扱いを簡単化しています。

Option ブロック `do ? <ブロック>` は、`<ブロック>` が `T` 型であるときに `?T` 型の値を生成します。`<ブロック>` からブレークされる可能性があることが重要です。 `<ブロック>` の中で、null ブレーク `<式> !` は、無関係な Option 型 `?U` の `<式>` の結果が `null` であるかどうかをテストします。 もし `<式>` の結果が `null` ならば、制御は直ちに `do ? <ブロック>` を終了し、その値は `null` となります。 結果が `null` でなければ、`<式>` の結果は Option 値 `?v` でなければならず、`<式> !` の評価はその内容である `v` (`U` 型) で進められます。

実際の例として、自然数、除算、ゼロかどうかのテストからなる数値式 `Exp` を評価する簡単な関数 `eval` を定義し、バリアント型としてエンコードしたものを以下に示します。

```motoko file=./examples/option-block.mo

```

`0` による除算をトラップせずに防ぐために、`eval` 関数は失敗を示す `null` を使用して Option 型の結果を返します。

それぞれの再帰呼び出しは `!` を使って `null` かどうかをチェックし、結果が `null` の場合は直ちに外側の `do ? block` と関数そのものを `null` 値を持って終了します。

（ Option ブロックの簡潔さを理解する演習として、ラベル付きの式を使用して `eval` を書き換えて、null 値ブレークごとに明示的に switch 式を入れてみるとよいでしょう。）

## `loop` を使った反復処理

一連の命令式を無限に繰り返す最も簡単な方法は、`loop` 構造を使うことです。

```motoko no-repl
loop { <expr1>; <expr2>; ... }
```

ループを抜けるには、`return` または `break` 構造を使用します。

ループを条件付きで繰り返すために、`loop ⟨本体⟩ while ⟨条件⟩` という再投入条件を付けることができます。

このようなループの本体は、常に少なくとも一度は実行されます。

## 前提条件付きの `while` ループ

ループの最初の実行を防ぐために、入力条件が必要な場合があります。このようなループ処理のために、 `while ⟨条件⟩ ⟨本体⟩` 式が利用可能です。

```motoko no-repl
while (earned < need) { earned += earn() };
```

`loop` とは異なり、`while` ループの本体は一度も実行されない可能性があります。

## イテレーションのための `for` ループ

ある同種のコレクションの要素に対する反復は、`for` ループを使って行うことができます。値はイテレータから引き出され、順番にループパターンに束縛されます。

```motoko
let carsInStock = [
  ("Buick", 2020, 23.000),
  ("Toyota", 2019, 17.500),
  ("Audi", 2020, 34.900)
];
var inventory : { var value : Float } = { var value = 0.0 };
for ((model, year, price) in carsInStock.vals()) {
  inventory.value += price;
};
inventory
```

## `for` ループにおける `range` の使用

`range` 関数は、与えられた下限値と上限値を持つ（`Iter<Nat>` 型の）イテレータを生成します。

次のループの例では、_11_ 回の反復処理で `0` から `10` までの数字を表示します。

```motoko
import Iter "mo:base/Iter";
import Debug "mo:base/Debug";
var i = 0;
for (j in Iter.range(0, 10)) {
  Debug.print(debug_show(j));
  assert(j == i);
  i += 1;
};
assert(i == 11);
```

より一般的には、`range` 関数は自然数列に対するイテレータを生成する `class` です。それぞれのイテレータは `Iter<Nat>` 型となります。

コンストラクタ関数として、`range` は以下の関数型を持ちます。

```motoko no-repl
(lower : Nat, upper : Int) -> Iter<Nat>
```

ここで `Iter<Nat>` は `next` メソッドを持つイテレータオブジェクト型であり、それぞれ `?Nat` 型の Option 要素を生成します。

```motoko no-repl
type Iter<A> = {next : () -> ?A};
```

各呼び出しに対して、`next` は（`?Nat` 型の）Option 要素を返します。

`null` 値は、反復処理のシーケンスが終了したことを示します。

`null` に達するまで、ある数 _n_ の `?`*n*の形式の非 `null` 値には、繰り返し処理における次の順番の要素が含まれます。

## `revRange` を使う

`range` と同様に、`revRange` 関数は（それぞれ `Iter<Int>` 型の）イテレータを生成する `class` です。 コンストラクタ関数として、この関数は以下の関数型を持っています。

```motoko no-repl
(upper : Int, lower : Int) -> Iter<Int>
```

`range` とは異なり、`revRange` 関数は、最初の _上限_ 値から最後の _下限_ 値まで、繰り返し計算の順序を _降順_ にします。

## 特定のデータ構造のイテレータを使用する

多くの組み込みデータ構造には、あらかじめイテレータが定義されています。以下の表は、それらの一覧です。

| Type      | Name                   | Iterator | Elements                  | Element type |
| --------- | ---------------------- | -------- | ------------------------- | ------------ |
| `[T]`     | array of `T`​s         | `vals`   | the array’s members       | `T`          |
| `[T]`     | array of `T`​s         | `keys`   | the array’s valid indices | `Nat`        |
| `[var T]` | mutable array of `T`​s | `vals`   | the array’s members       | `T`          |
| `[var T]` | mutable array of `T`​s | `keys`   | the array’s valid indices | `Nat`        |
| `Text`    | text                   | `chars`  | the text’s characters     | `Char`       |
| `Blob`    | blob                   | `vals`   | the blob’s bytes          | `Nat8`       |

データ構造のイテレータ

ユーザー定義のデータ構造では、独自のイテレータを定義することができます。ある要素型 `A` に対して `Iter<A>` 型になっている限り、これらは組み込みのものと同じように振る舞い、通常の `for` ループで使用することができます。

<!--

# Imperative control flow

There are two key categories of control flow:

-   *declarative*, when the structure of some value guides control and the selection of the next expression to evaluate, like in `if` and `switch` expressions;

-   *imperative* where control changes abruptly according to a programmer’s command, abondoning regular control flow; examples are `break` and `continue`, but also `return` and `throw`.

Imperative control flow often goes hand-in-hand with state changes and other flavors of side-effects, such as error handling and input/output.

## Early `return` from `func`

Normally, the result of a function is the value of its body. Sometimes, during evaluation of the body, the result is available before the end of evaluation. In such situations the `return <exp>` construct can be used to abandon the rest of the computation and immediately exit the function with a result. Similarly, where permitted, `throw` may be used to abandon a computation with an error.

When a function has unit result type, the shorthand `return` may be used instead of the equivalent `return ()`.

## Loops and labels

Motoko provides several kinds of repetition constructs, including:

-   `for` expressions for iterating over members of structured data.

-   `loop` expressions for programmatic repetition (optionally with termination condition).

-   `while` loops for programmatic repetition with entry condition.

Any of these can be prefixed with a `label <name>` qualifier to give the loop a symbolic name. Named loops are useful for imperatively changing control flow to continue from the entry or exit of the named loop.

-   re-entering the loop with `continue <name>`, or

-   exiting the loop altogether with `break <name>`.

In the following example, the `for` expression loops over characters of some text and abandons iteration as soon as an exclamation sign is encountered.

``` motoko
import Debug "mo:base/Debug";
label letters for (c in "ran!!dom".chars()) {
  Debug.print(debug_show(c));
  if (c == '!') { break letters };
  // ...
}
```

### Labeled expressions

There are two other facets to `label`​s that are less mainstream, but come in handy in certain situations:

-   `label`​s can be typed

-   *any* expression (not just loops) can be named by prefixing it with a label; `break` allows one to short-circuit the expression’s evaluation by providing an immediate value for its result. (This is similar to exiting a function early using `return`, but without the overhead of declaring and calling a function.)

The syntax for type-annotated labels is `label <name> : <type> <expr>`, signifying that any expression can be exited using a `break <name> <alt-expr>` construct that returns the value of `<alt-expr>` as the value of `<expr>`, short-circuiting evaluation of `<expr>`.

Judicious use of these constructs allows the programmer to focus on the primary program logic and handle exceptional case via `break`

``` motoko
import Text "mo:base/Text";
import Iter "mo:base/Iter";

type Host = Text;
let formInput = "us@dfn";

let address = label exit : ?(Text, Host) {
  let splitted = Text.split(formInput, #char '@');
  let array = Iter.toArray<Text>(splitted);
  if (array.size() != 2) { break exit(null) };
  let account = array[0];
  let host = array[1];
  // if (not (parseHost(host))) { break exit(null) };
  ?(account, host)
}
```

Naturally, labeled common expressions don’t allow `continue`. In terms of typing, both `<expr>` and `<alt-expr>`​'s types must conform with the label’s declared `<type>`. If a label is only given a `<name>`, then its `<type>` defaults to unit (`()`). Similarly a `break` without an `<alt-expr>` is shorthand for the value unit (`()`).

## Option blocks and null breaks

Like many other high-level languages, Motoko lets you opt in to `null` values, tracking possible occurences of `null` values using option types of the form `?T`. This is to both to encourage you to avoid using `null` values when possible, and to consider the possibility of `null` values when necessary.

The latter could be cumbersome, if the only way to test a value for `null` were with a verbose `switch` expression, but Motoko simplifies the handling of option types with some dedicated syntax: *option blocks* and *null breaks*.

The option block, `do ? <block>`, produces a value of type `?T`, when block `<block>` has type `T` and, importantly, introduces the possibility of a break from `<block>`. Within a `do ? <block>`, the null break `<exp> !`, tests whether the result of the expression, `<exp>`, of unrelated option type, `?U`, is `null`. If the result `<exp>` is `null`, control immediately exits the `do ? <block>` with value `null`. Otherwise, the result of `<exp>` must be an option value `?v`, and evaluation of `<exp> !` proceeds with its contents, `v` (of type `U`).

As realistic example, we give the definition of a simple function `eval`uating numeric `Exp`ressions built from natural numbers, division and a zero test, encoded as a variant type:

-->
<!--
TODO: make interactive
-->
<!--

``` motoko file=./examples/option-block.mo
```

To guard against division by `0` without trapping, the `eval` function returns an option result, using `null` to indicate failure.

Each recursive call is checked for `null` using `!`, immediately exiting the outer `do ? block`, and thus the function itself, with `null`, when a result is `null`.

(As an exercise that illustrates the concision of option blocks, you might want to try rewriting `eval` using a labeled expression and explicit switches for each null break.)

## Repetition with `loop`

The simplest way to indefinitely repeat a sequence of imperative expressions is by using a `loop` construct

``` motoko no-repl
loop { <expr1>; <expr2>; ... }
```

The loop can only be abandoned with a `return` or `break` construct.

A re-entry condition can be affixed to allow a conditional repetition of the loop with `loop <body> while <cond>`.

The body of such a loop is always executed at least once.

## `while` loops with precondition

Sometimes an entry condition is needed to guard the first execution of a loop. For this kind of repetition the `while <cond> <body>`-flavor is available

``` motoko no-repl
while (earned < need) { earned += earn() };
```

Unlike a `loop`, the body of a `while` loop may never be executed.

## `for` loops for iteration

An iteration over elements of some homogeneous collection can be performed using a `for` loop. The values are drawn from an iterator and bound to the loop pattern in turn.

``` motoko
let carsInStock = [
  ("Buick", 2020, 23.000),
  ("Toyota", 2019, 17.500),
  ("Audi", 2020, 34.900)
];
var inventory : { var value : Float } = { var value = 0.0 };
for ((model, year, price) in carsInStock.vals()) {
  inventory.value += price;
};
inventory
```

## Using `range` with a `for` loop

The `range` function produces an iterator (of type `Iter<Nat>`) with the given lower and upper bound, inclusive.

The following loop example prints the numbers `0` through `10` over its *eleven* iterations:

``` motoko
import Iter "mo:base/Iter";
import Debug "mo:base/Debug";
var i = 0;
for (j in Iter.range(0, 10)) {
  Debug.print(debug_show(j));
  assert(j == i);
  i += 1;
};
assert(i == 11);
```

More generally, the function `range` is a `class` that constructs iterators over sequences of natural numbers. Each such iterator has type `Iter<Nat>`.

As a constructor function, `range` has a function type:

``` motoko no-repl
(lower : Nat, upper : Int) -> Iter<Nat>
```

Where `Iter<Nat>` is an iterator object type with a `next` method that produces optional elements, each of type `?Nat`:

``` motoko no-repl
type Iter<A> = {next : () -> ?A};
```

For each invocation, `next` returns an optional element (of type `?Nat`).

The value `null` indicates that the iteration sequence has terminated.

Until reaching `null`, each non-`null` value, of the form `?`*n* for some number *n*, contains the next successive element in the iteration sequence.

## Using `revRange`

Like `range`, the function `revRange` is a `class` that constructs iterators (each of type `Iter<Int>`). As a constructor function, it has a function type:

``` motoko no-repl
(upper : Int, lower : Int) -> Iter<Int>
```

Unlike `range`, the `revRange` function *descends* in its iteration sequence, from an initial *upper* bound to a final *lower* bound.

## Using iterators of specific data structures

Many built-in data structures come with pre-defined iterators. Below table lists them

| Type      | Name                  | Iterator | Elements                  | Element type |
|-----------|-----------------------|----------|---------------------------|--------------|
| `[T]`     | array of `T`​s         | `vals`   | the array’s members       | `T`          |
| `[T]`     | array of `T`​s         | `keys`   | the array’s valid indices | `Nat`        |
| `[var T]` | mutable array of `T`​s | `vals`   | the array’s members       | `T`          |
| `[var T]` | mutable array of `T`​s | `keys`   | the array’s valid indices | `Nat`        |
| `Text`    | text                  | `chars`  | the text’s characters     | `Char`       |
| `Blob`    | blob                  | `vals`   | the blob’s bytes          | `Nat8`       |

Iterators for data structures

User-defined data structures can define their own iterators. As long they conform with the `Iter<A>` type for some element type `A`, these behave like the built-in ones and can be consumed with ordinary `for`-loops.

-->
