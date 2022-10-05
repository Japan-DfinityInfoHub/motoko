# ミュータブルなステート

Motoko の各 Actor は、内部のミュータブル（可変）なステートを使用することはできますが、_決して直接共有することはできません_ 。

後ほど、[Actor 間の共有](sharing.md)について議論しますが、 これは Actor が _イミュータブル_ （不変）な データやハンドルを、shared 関数として提供されている外部エントリーポイントに送受信するものです。 これらの共有可能なデータを送受信する場合とは異なり、Motoko の設計上の重要な不変性は、**\*ミュータブルなデータ**は、それを割り当てた Actor の内部（プライベート）に保持され、**リモートで共有されることは決してない**ということです\* 。

この章では、（プライベートな）Actor のステートを用いて、値の変更操作を行って時間の経過とともにステートの値を変化させる方法を、最小限の例を使って説明します。

[ローカルオブジェクトとクラス](local-objects-classes.md)では、ローカルオブジェクトの構文と、1 つのミュータブルな変数を持つ最小構成の `counter` Actor を紹介しています。 [次の章](actors-async.md)では、同じ動作をする Actor を用いますが、リモートで使用するための Service インターフェースによって間接的に counter 変数を公開する方法について説明しています。

## イミュータブルな変数 vs ミュータブルな変数

`var` 構文は、宣言ブロックの中でミュータブルな変数を宣言します：

```motoko name=init
let text  : Text = "abc";
let num  : Nat = 30;

var pair : (Text, Nat) = (text, num);
var text2 : Text = text;
```

上記の宣言リストでは、4 つの変数を宣言しています。 最初の 2 つの変数 (`text` と `num`) は字句スコープされた _イミュータブルな変数_ です。 最後の 2 つの変数 (`pair` と `text2`) は字句スコープされた **_ミュータブルな_** 変数です。

## ミュータブルなメモリへの割り当て

ミュータブルな変数には代入が可能ですが、イミュータブルな変数には代入ができません。

上記の `text` や `num` に新しい値を代入しようとすると、これらの変数はイミュータブルなので静的型エラーが発生します。

しかし、ミュータブルな変数である `pair` と `text2` の値は、以下のように `:=` で表される代入の構文を使って自由に更新することができます：

```motoko include=init
text2 := text2 # "xyz";
pair := (text2, pair.1);
pair
```

上記では、各変数の値に単純な `更新ルール` を適用することで各変数を更新しています（例えば、`text2` の接尾辞に文字列 `"xyz"` を付加することで _更新_ しています）。 同様に、Actor は内部（プライベート）のミュータブルな変数に対して同じ代入構文を使用して _update_ を実行することで、更新の呼び出しを処理します。

### 特殊な代入操作

代入操作 `:=` は一般的であり、すべての型に対して機能します。

また、Motoko には、代入と二項演算（2 つの数から新たな数を決定する演算）を組み合わせた特殊な代入操作もあります。代入値は、与えられたオペランド（被演算子）に対する二項演算と、代入された変数の現在の値を使用します。

例えば数字では、加算と同時に代入することが可能です：

```motoko
var num2 = 2;
num2 += 40;
num2
```

2 行目以降の変数 `num2` には、期待する通り `42` が格納されます。

Motoko には、他の代入と二項演算の組み合わせもあります。例えば、`text2` を更新する上の行を、より簡潔に次のように書き換えることができます：

```motoko include=init
text2 #= "xyz";
text2
```

`+=` と同様に、代入される変数の名前を（特殊）代入演算子 `#=` の右側で繰り返すことを避けることができます。

[代入演算](language-manual.md#assignment-operators) の全リストに、適切な型（数値、ブール、テキスト値）に対する数値、論理、テキストの演算の一覧が記載されています。

## ミュータブルなメモリからの読み込み

各変数を更新する際には、特殊な構文なしに、ミュータブルな値を最初に _読み込み_ しています。

これは細かいポイントを示しています。それぞれのミュータブルな変数の使用は、イミュータブルな変数の使用のように _見え_ ますが、実際にはイミュータブルな変数のようには _動作_ しません。 実際、その意味はさらに複雑です。すべての言語ではありませんが、多くの言語（JavaScript、Java、C# など）では、それぞれの構文は、その変数で特定されるメモリのセルにアクセスして現在の値を取得する _メモリ効果_ を隠蔽しています。関数型言語の伝統を持つ他の言語（SML、OCaml、Haskell など）では、一般的にこれらの作用を構文的に公開しています。

以下では，この点について詳しく説明します：

## `var` と `let` の違いについて理解する

次の 2 つのよく似た変数宣言を考えてみましょう：

```motoko
let x : Nat = 0
```

と

```motoko
var x : Nat = 0
```

これらの構文の唯一の違いは変数 `x` を定義するのにキーワード `let` と `var` を使用していることで、いずれもプログラムは `0` に初期化します。

しかしながら、これらのプログラムは異なる意味を持っており、より大きなプログラムの文脈では、その意味の違いが `x` の使われ方の意味に影響を及ぼします。

`let` を使用している最初のプログラムでは、`x` が `0` であることを _意味して_ います。 `x` が使われている箇所を `0` に置き換えても、プログラムの意味は変わりません。

`var` を使った 2 つ目のプログラムでは、それぞれの `x` は「`x` という名前の、ミュータブルなメモリセルの現在の値を読み込んで生成する」ということを _意味して_ います。 この場合、それぞれの `x` の値は動的な状態（`x` という名前のミュータブルなメモリセルの内容）によって決定されます。

上記の定義からわかるように、`let` に束縛された変数と `var` に束縛された変数の意味には根本的な違いがあります。

大規模なプログラムでは、どちらの種類の変数も有用であり、どちらかがもう一方のよい代替とはなりません。

ただし、`let` 変数はより基本的なものです。

その理由を知るため、`let` 変数 1 要素のミュータブルな配列を使って、`var` 変数を書き表すことを考えてみましょう。

例えば、`0` で初期化されたミュータブルな変数として `x` を宣言することは、1 要素（`0`）のミュータブルな配列を示す、イミュータブルな変数 `y` によって代替することが可能です：

```motoko
var x : Nat       = 0 ;
let y : [var Nat] = [var 0] ;
```

ミュータブルな配列の詳細については[以下](#mutable-arrays)で説明します。

残念ながら、この書き方に用いた読み書きの構文は、ミュータブルな配列の構文を再利用しており、`var` 変数の構文ほど読みやすくありません。 つまり、変数 `x` の読み書きの仕方は、変数 `y` の読み書きの仕方よりも読みやすいです。

このような実用上の理由から、`var` 変数は、言語設計の中核をなすものです。

## イミュータブルな配列

[ミュータブルな配列](#mutable-arrays)について説明する前に、同じ射影（値の抽出）の構文を持ち、割り当て後の可変的な更新（代入）を許可しないイミュータブルな配列について説明します。

### イミュータブルな定数配列の割り当て

```motoko name=array
let a : [Nat] = [1, 2, 3] ;
```

上の配列 `a` は 3 つの自然数を保持しており、型は `[Nat]` です。 一般に、イミュータブルな配列の型は `[_]` であり、配列の要素の型を角括弧で囲んで表現します。要素の型は配列内で共通となる単一の型である必要があり、今回の場合は `Nat` です。

### 配列のインデックスからの射影（値の読み込み）について

配列からの射影（_読み込み_）には、角括弧（`[` と `]`）でアクセスしたいインデックスを囲む、よくあるブラケット構文を用いることができます：

```motoko include=array
let x : Nat = a[2] + a[0] ;
```

Motoko において配列へのアクセスはすべて安全です。 範囲外へのアクセスは危険なメモリアクセスを引き起こさず、代わりに [アサーションの失敗](basic-concepts.md#assertions)のようにプログラムがトラップされます。

## 配列モジュール

Motoko 標準ライブラリは、ミュータブルな配列およびイミュータブルな配列に対する基本的な操作を提供しています。以下のようにインポートできます。

```motoko name=import
import Array "mo:base/Array";
```

この章では、最も頻繁に使用される配列操作について説明します。 配列の使い方の詳細については、[配列](./base/Array.md)ライブラリの説明をご覧ください。

### イミュータブルな配列へのさまざまな要素の割り当て

上記では、イミュータブルな配列を作成するためのごく限られた方法を示しました。

一般的に、プログラムによって割り当てられた新しい配列はさまざまな値を含みます。突然値が変わるようなことがないのであれば、要素群を割り当ての引数で "一度に" 指定する方法が必要です。

このようなニーズに対応するために、Motoko 言語では、要素ごとに値を決めるためにユーザー指定の "生成関数" である `gen` を参照する、_高次の_ 配列割り当て関数 `Array.tabulate` を用意しています。

```motoko no-repl
func tabulate<T>(size : Nat,  gen : Nat -> T) : [T]
```

`gen` 関数は、アロー関数型 `Nat → T` （ここで `T` は最終的な配列要素の型）の _関数値_ として配列を指定します。

`gen` 関数は、配列の初期化時に配列として実際に _機能_ します。つまり、配列要素のインデックスを受け取り、そのインデックスに割り当てられる（`T` 型の）要素を生成して返します。 出力された配列は、`gen` 関数の指定に基づいて自らの配列に値を追加します。

例えば、最初にいくつかの初期定数からなる `array1` を割り当て、次にインデックスの一部を（純粋な、関数型な方法で）変更してアップデートを行い、2 番目の配列である `array2` を非破壊的に生成することができます。

```motoko include=import
let array1 : [Nat] = [1, 2, 3, 4, 6, 7, 8] ;

let array2 : [Nat] = Array.tabulate<Nat>(7, func(i:Nat) : Nat {
    if ( i == 2 or i == 5 ) { array1[i] * i } // change 3rd and 6th entries
    else { array1[i] } // no change to other entries
  }) ;
```

関数型の要領で `array1` を `array2` に変更しているものの、両方の配列と両方の変数はイミュータブルであることに注意してください。

次に、根本的に異なる _ミュータブル_ な配列について考えてみましょう。

## ミュータブルな配列

上ではミュータブルな配列と同じ射影の構文を持つ _イミュータブルな配列_ を紹介しましたが、イミュータブルな配列は値の割り当て後のミュータブルな更新（割り当て）を許可していません。イミュータブルな配列とは異なり、Motoko のミュータブルな配列は、（プライベートで）ミュータブルな Actor のステートを導入します。

Motoko の型システムでは、リモートの Actor がミュータブルなステートを共有しないことを強制しているため、ミュータブルな配列とイミュータブルな配列との間に確固たる区別がされており、これは型付け・サブタイピング・非同期通信のための言語抽象化に影響を与えています。

より身近な例として、ミュータブルな配列はイミュータブルな配列を想定している場所では使用できません。これは、Motoko における配列の [サブタイピング](language-manual.md#subtyping) の定義が、型健全性の目的でそれらのケースを（正しく）区別しているためです。

加えて、Actor 通信の観点では、イミュータブルな配列は送信したり共有したりしても安全ですが、ミュータブルな配列はメッセージで共有したり送信したりすることはできません。 イミュータブルな配列とは異なり、ミュータブルな配列は _共有不可型_ を持ちます。

### ミュータブルな定数配列の割り当て

_ミュータブルな_ 配列の割り当てであることを示すために（_イミュータブルな_ 配列の形式とは対照的に）、ミュータブルな配列の構文 `[var _]` では、式と型の両方で `var` キーワードを使用します：

```motoko
let a : [var Nat] = [var 1, 2, 3] ;
```

上記の例と同様に、配列 `a` は 3 つの自然数を保持していますが、型は `[var Nat]` です。

### 動的サイズのミュータブルな配列の割り当て

サイズが一定でないミュータブルな配列を割り当てるには、`Array_init` プリミティブを使用して、初期値を指定します：

```motoko no-repl
func init<T>(size : Nat,  x : T) : [var T]
```

例えば：

```motoko include=import
var size : Nat = 42 ;
let x : [var Nat] = Array.init<Nat>(size, 3);
```

ここで、`size` は定数である必要はありません。 配列は `size` 個の要素を持ち、それぞれが初期値である `3` を保持します。

### ミュータブルな更新

ミュータブルな配列は、それぞれ `[var _]` という型を持ち、個々の要素への代入によるミュータブルな更新を許可します。以下の例では、要素のインデックス `2` が保持していた `3` の代わりに値 `42` を保持するように更新されます：

```motoko
let a : [var Nat] = [var 1, 2, 3];
a[2] := 42;
a
```

### サブタイピングでは、_ミュータブル_ を _イミュータブル_ として使用することはできません

Motoko のサブタイピングでは、`[Nat]` 型のイミュータブルな配列を期待する場所で、`[var Nat]` 型のミュータブルな配列を使用することはできません。

これには 2 つの理由があります。 第一に、すべてのミュータブルなステートと同様、ミュータブルな配列は健全なサブタイピングのために異なるルールを必要とします。 特に、ミュータブルな配列は、必然的に柔軟性の低いサブタイピングの定義を持ちます。 第二に、Motoko は [非同期通信](actors-async.md) でのミュータブルな配列の使用を禁止しており、ミュータブルなステートは決して共有されません。

<!--
# Mutable state

Each actor in Motoko may use, but may *never directly share*, internal mutable state.

Later, we discuss [sharing among actors](sharing.md), where actors send and receive *immutable* data, and also handles to each others external entry points, which serve as *shareable functions*. Unlike those cases of shareable data, a key Motoko design invariant is that ***mutable data** is kept internal (private) to the actor that allocates it, and **is never shared remotely***.

In this chapter, we continue using minimal examples to show how to introduce (private) actor state, and use mutation operations to change it over time.

In [local objects and classes](local-objects-classes.md), we introduce the syntax for local objects, and a minimal `counter` actor with a single mutable variable. In the [following chapter](actors-async.md), we show an actor with the same behavior, exposing the counter variable indirectly behind an associated service interface for using it remotely.

## Immutable versus mutable variables

The `var` syntax declares mutable variables in a declaration block:

``` motoko name=init
let text  : Text = "abc";
let num  : Nat = 30;

var pair : (Text, Nat) = (text, num);
var text2 : Text = text;
```

The declaration list above declares four variables. The first two variables (`text` and `num`) are lexically-scoped, *immutable variables*. The final two variables (`pair` and `text2`) are lexically-scoped, ***mutable*** variables.

## Assignment to mutable memory

Mutable variables permit assignment, and immutable variables do not.

If we try to assign new values to either `text` or `num` above, we will get static type errors; these variables are immutable.

However, we may freely update the value of mutable variables `pair` and `text2` using the syntax for assignment, written as `:=`, as follows:

``` motoko include=init
text2 := text2 # "xyz";
pair := (text2, pair.1);
pair
```

Above, we update each variable based on applying a simple “update rule” to their current values (for example, we *update* `text2` by appending string constant `"xyz"` to its suffix). Likewise, an actor processes some calls by performing *updates* on its internal (private) mutable variables, using the same assignment syntax as above.

### Special assignment operations

The assignment operation `:=` is general, and works for all types.

Motoko also includes special assignment operations that combine assignment with a binary operation. The assigned value uses the binary operation on a given operand and the current contents of the assigned variable.

For example, numbers permit a combination of assignment and addition:

``` motoko
var num2 = 2;
num2 += 40;
num2
```

After the second line, the variable `num2` holds `42`, as one would expect.

Motoko includes other combinations as well. For example, we can rewrite the line above that updates `text2` more concisely as:

``` motoko include=init
text2 #= "xyz";
text2
```

As with `+=`, this combined form avoids repeating the assigned variable’s name on the right hand side of the (special) assignment operator `#=`.

The full table [assignment operators](language-manual.md#assignment-operators) lists numerical, logical, and textual operations over appropriate types (number, boolean and text values, respectively).

## Reading from mutable memory

When we updated each variable, we also first *read* from the mutable contents, with no special syntax.

This illustrates a subtle point: Each use of a mutable variable *looks like* the use of an immutable variable, but does not *act like* one. In fact, its meaning is more complex. As in many languages (JavaScript, Java, C#, etc.), but not all, the syntax of each use hides the *memory effect* that accesses the memory cell identified by that variable, and gets its current value. Other languages from functional traditions (SML, OCaml, Haskell, etc), generally expose these effects syntactically.

Below, we explore this point in detail.

## Understanding `var`- versus `let`-bound variables

Consider the following two variable declarations, which look similar:

``` motoko
let x : Nat = 0
```

and:

``` motoko
var x : Nat = 0
```

The only difference in their syntax is the use of keyword `let` versus `var` to define the variable `x`, which in each case the program initializes to `0`.

However, these programs carry different meanings, and in the context of larger programs, the difference in meanings will impact the meaning of each occurrence of `x`.

For the first program, which uses `let`, each such occurrence *means* `0`. Replacing each occurrence with `0` will not change the meaning of the program.

For the second program, which uses `var`, each occurrence *means*: “read and produce the current value of the mutable memory cell named `x`.” In this case, each occurrence’s value is determined by dynamic state: the contents of the mutable memory cell named `x`.

As one can see from the definitions above, there is a fundamental contrast between the meanings of `let`-bound and `var`-bound variables.

In large programs, both kinds of variables can be useful, and neither kind serves as a good replacement for the other.

However, `let`-bound variables *are* more fundamental.

To see why, consider encoding a `var`-bound variable using a one-element, mutable array, itself bound using a `let`-bound variable.

For instance, instead of declaring `x` as a mutable variable initially holding `0`, we could instead use `y`, an immutable variable that denotes a mutable array with one entry, holding `0`:

``` motoko
var x : Nat       = 0 ;
let y : [var Nat] = [var 0] ;
```

We explain mutable arrays in more detail [below](#mutable-arrays).

Unfortunately, the read and write syntax required for this encoding reuses that of mutable arrays, which is not as readable as that of `var`-bound variables. As such, the reads and writes of variable `x` will be easier to read than those of variable `y`.

For this practical reason, and others, `var`-bound variables are a core aspect of the language design.

## Immutable arrays

Before discussing [mutable arrays](#mutable-arrays), we introduce immutable arrays, which share the same projection syntax, but do not permit mutable updates (assignments) after allocation.

### Allocate an immutable array of constants

``` motoko name=array
let a : [Nat] = [1, 2, 3] ;
```

The array `a` above holds three natural numbers, and has type `[Nat]`. In general, the type of an immutable array is `[_]`, using square brackets around the type of the array’s elements, which must share a single common type, in this case `Nat`.

### Project from (read from) an array index

We can project from (*read from*) an array using the usual bracket syntax (`[` and `]`) around the index we want to access:

``` motoko include=array
let x : Nat = a[2] + a[0] ;
```

Every array access in Motoko is safe. Accesses that are out of bounds will not access memory unsafely, but instead will cause the program to trap, as with an [assertion](basic-concepts.md#assertions) failure.

## The Array module

The Motoko standard library provides basic operations for immutable and mutable arrays. It can be imported as follows,

``` motoko name=import
import Array "mo:base/Array";
```

In this section, we discuss some of the most frequently used array operations. For more information about using arrays, see the [Array](./base/Array.md) library descriptions.

### Allocate an immutable array with varying content

Above, we showed a limited way of creating immutable arrays.

In general, each new array allocated by a program will contain a varying number of varying elements. Without mutation, we need a way to specify this family of elements "all at once", in the argument to allocation.

To accommodate this need, the Motoko language provides *the higher-order* array-allocation function `Array.tabulate`, which allocates a new array by consulting a user-provided "generation function" `gen` for each element.

``` motoko no-repl
func tabulate<T>(size : Nat,  gen : Nat -> T) : [T]
```

Function `gen` specifies the array *as a function value* of arrow type `Nat → T`, where `T` is the final array element type.

The function `gen` actually *functions* as the array during its initialization: It receives the index of the array element, and it produces the element (of type `T`) that should reside at that index in the array. The allocated output array populates itself based on this specification.

For instance, we can first allocate `array1` consisting of some initial constants, and then functionally-update *some* of the indices by "changing" them (in a pure, functional way), to produce `array2`, a second array that does not destroy the first.

``` motoko include=import
let array1 : [Nat] = [1, 2, 3, 4, 6, 7, 8] ;

let array2 : [Nat] = Array.tabulate<Nat>(7, func(i:Nat) : Nat {
    if ( i == 2 or i == 5 ) { array1[i] * i } // change 3rd and 6th entries
    else { array1[i] } // no change to other entries
  }) ;
```

Even though we "changed" `array1` into `array2` in a functional sense, notice that both arrays and both variables are immutable.

Next, we consider *mutable* arrays, which are fundamentally distinct.

## Mutable arrays

Above, we introduced *immutable* arrays, which share the same projection syntax as mutable arrays, but do not permit mutable updates (assignments) after allocation. Unlike immutable arrays, each mutable array in Motoko introduces (private) mutable actor state.

Because Motoko’s type system enforces that remote actors do not share their mutable state, the Motoko type system introduces a firm distinction between mutable and immutable arrays that impacts typing, subtyping and the language abstractions for asynchronous communication.

Locally, the mutable arrays can not be used in places that expect immutable ones, since Motoko’s definition of [subtyping](language-manual.md#subtyping) for arrays (correctly) distinguishes those cases for the purposes of type soundness. Additionally, in terms of actor communication, immutable arrays are safe to send and share, while mutable arrays can not be shared or otherwise sent in messages. Unlike immutable arrays, mutable arrays have *non-shareable types*.

### Allocate a mutable array of constants

To indicate allocation of *mutable* arrays (in contrast to the forms above, for immutable ones), the mutable array syntax `[var _]` uses the `var` keyword, in both the expression and type forms:

``` motoko
let a : [var Nat] = [var 1, 2, 3] ;
```

As above, the array `a` above holds three natural numbers, but has type `[var Nat]`.

### Allocate a mutable array with dynamic size

To allocate mutable arrays of non-constant size, use the `Array_init` primitive, and supply an initial value:

``` motoko no-repl
func init<T>(size : Nat,  x : T) : [var T]
```

For example:

``` motoko include=import
var size : Nat = 42 ;
let x : [var Nat] = Array.init<Nat>(size, 3);
```

The variable `size` need not be constant here; the array will have `size` number of entries, each holding the initial value `3`.

### Mutable updates

Mutable arrays, each with type form `[var _]`, permit mutable updates via assignment to an individual element, in this case element index `2` gets updated from holding `3` to instead hold value `42`:

``` motoko
let a : [var Nat] = [var 1, 2, 3];
a[2] := 42;
a
```

### Subtyping does not permit *mutable* to be used as *immutable*

Subtyping in Motoko does not permit us to use a mutable array of type `[var Nat]` in places that expect an immutable one of type `[Nat]`.

There are two reasons for this. First, as with all mutable state, mutable arrays require different rules for sound subtyping. In particular, mutable arrays have a less flexible subtyping definition, necessarily. Second, Motoko forbids uses of mutable arrays across [asynchronous communication](actors-async.md), where mutable state is never shared.

-->
