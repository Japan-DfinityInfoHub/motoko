# パターンマッチング

パターンマッチングとは、構造化されたデータのテストとその構成要素への分解を容易にする言語機能です。ほとんどのプログラミング言語では、構造化データを構築するための機能が馴染みの方法で用意されていますが、パターンマッチングでは、構造化データを分解し、その断片を指定した名前に束縛（bind）することでスコープ内に取り込むことができます。 構文的には、パターンは構造化データの構築に似ていますが、一般的に関数の引数の位置や、`switch` 式の `case` キーワードの後や、`let` や `var` 宣言の後など、入力を指示する場所に出現します。

以下の関数呼び出しを考えてみましょう。

```motoko include=fullname
let name : Text = fullName({ first = "Jane"; mid = "M"; last = "Doe" });
```

このコードでは、3 つのフィールドを持つレコードを作成し、関数 `fullName` に渡しています。関数呼び出しの結果には名前が付けられ、識別子である `name` に束縛されることでスコープに取り込まれます。最後の束縛部分がパターンマッチングと呼ばれており、`name : Text` は最も単純なパターン形式の一つです。例えば、次のような関数の実装を考えます。

```motoko name=fullname
func fullName({ first : Text; mid : Text; last : Text }) : Text {
  first # " " # mid # " " # last
};
```

入力は（匿名の）オブジェクトで、3 つの `Text` フィールドに分解され、その値は識別子 `first`、`mid`、`last` に束縛されます。これらのフィールドは、関数本体のブロックの中で自由に使用することができます。上記では、オブジェクトのフィールドパターンを別名付け（aliasing）の一種である _名前のパニング_（name punning; 別の名前を付けること）を使って、フィールドの名前と一致させています。より一般的には、`…​; mid = m : Text; …​` のように、フィールドとは別の名前を付けることができます。ここでは `mid` がどのフィールドにマッチするかを決定し、`m` がスコープ内で用いられる名前を決定します。

パターンマッチングを使用して、リテラル定数のような _リテラルパターン_ を宣言することもできます。リテラルパターンは `switch` 式で特に便利です。なぜなら、現在のパターンマッチングを _失敗_ させ、次のパターンへのマッチングに進ませることができるからです。例えば、以下のようになります。

```motoko
switch ("Adrienne", #female) {
  case (name, #female) { name # " is a girl!" };
  case (name, #male) { name # " is a boy!" };
  case (name, _) { name # ", is a human!" };
}
```

上のパターンは最初の `case` 節にマッチし (識別子 `name` への束縛は失敗せず、短縮形のバリアントリテラル `#Female` は等しいと比較されるから)、`"Adrienne is a girl!"` と評価されます。最後の節は、_ワイルドカード_ パターン `_` の例を示しています。これは失敗することはないですが、識別子を束縛することはありません。

最後のパターンは `or` パターンです。その名前が示すように、これは 2 つ以上のパターンを `or` というキーワードで区切ったものです。それぞれのサブパターンは同じ識別子のセットに束縛されなければならず、左から右へとマッチングされます。`or` パターンは、一番右のサブパターンが失敗したときに失敗します。

| pattern kind               | example(s)                       | context    | can fail                              | remarks                                  |
| -------------------------- | -------------------------------- | ---------- | ------------------------------------- | ---------------------------------------- |
| literal                    | `null`, `42`, `()`, `"Hi"`       | everywhere | when the type has more than one value |                                          |
| named                      | `age`, `x`                       | everywhere | no                                    | introduces identifiers into a new scope  |
| wildcard                   | `_`                              | everywhere | no                                    |                                          |
| typed                      | `age : Nat`                      | everywhere | conditional                           |                                          |
| option                     | `?0`, `?val`                     | everywhere | yes                                   |                                          |
| tuple                      | `( component0, component1, …​ )` | everywhere | conditional                           | must have at least two components        |
| object                     | `{ fieldA; fieldB; …​ }`         | everywhere | conditional                           | allowed to mention a subset of fields    |
| field                      | `age`, `count = 0`               | object     | conditional                           | `age` is short for `age = age`           |
| variant                    | `#celsius deg`, `#sunday`        | everywhere | yes                                   | `#sunday` is short form for `#sunday ()` |
| alternative (`or`-pattern) | `0 or 1`                         | everywhere | depends                               | no alternative may bind an identifier    |

このテーブルはパターンマッチングの種々の方法をまとめたものです。

## パターンに関する追加情報

パターンマッチングには豊富な歴史と興味深い仕組みがあるため、いくつかの補足説明をさせていただきます。

用語  
マッチングされる（通常は構造化された）式はしばしば _被検査体_（scrutinee; パターンマッチングされる対象）と呼ばれ、`case` キーワードの後ろに現れるパターンは _選択肢_（alternative）と呼ばれます。すべての可能な被検査体が（少なくとも一つの）選択肢とマッチするとき、被検査体は _カバーされている_ と言います。パターンはトップダウン方式で試行されるので、パターンが重複している場合は上位のものが選択されます。ある選択肢にマッチするすべての値に対して上位の選択肢がある場合、その選択肢は _無効_（dead）（または _非アクティブ_）とみなされます。

ブーリアン  
データ型 `Bool` は 2 つに分離された選択肢（`true` と `false` ）とみなすことができ、Motoko の組み込み `if` 構造体がデータを _排除_ して _制御_ フローに変換します。`if` 式はパターンマッチングの一種で、一般的な `switch` 式をブーリアン被検査体という特殊なケースに対して省略して書けるようにしたものです。

バリアントパターン  
Motoko のバリアント型は _非交和_ （disjoint union） の一種です（_直和型_ （sum type）とも呼ばれることがあります）。バリアント型の値は常にただ 1 つの _判別器_（discriminator）と、判別器ごとに異なる可能性のあるペイロードを持っています。バリアントパターンとバリアント値をマッチングするとき、判別器は（選択肢を選ぶために）同じでなければならず、そうであればペイロードはさらなるマッチングのために公開されます。

列挙型  
他のプログラミング言語はしばしば列挙を表すために `enum` というキーワードを使用します（例えば C 言語はそうですが、 Motoko はそうではありません）。これらは選択肢がペイロードを持つことができないため、Motoko のバリアント型の貧弱な親戚のようなものです。同様に、これらの言語では `switch` のような文はパターンマッチングの一部の機能を持っていません。Motoko にはペイロードを必要としない基本的な列挙型を定義するためのショートハンド構文（例: `type Weekday = { #mon; #tue; …​ }`）があります。

エラー処理  
エラー処理は、パターンマッチングのユースケースの一つと考えることができます。関数が成功時の選択肢と失敗時の選択肢を持つ値を返す場合（例えば Option 値やバリアント）、[エラー処理](errors.md) で説明したように、パターンマッチングを使ってその 2 つを判別することができます。

論駁不可能（irrefutable）なマッチング  
単一の値だけを含むような型があります。私たちはこれを _シングルトン_ 型と呼んでいます。これらの例としては、ユニット型（空のタプル）やシングルトン型のタプルがあります。タグが 1 つでペイロードがない（またはシングルトン型である）バリアントも同様にシングルトン型です。シングルトン型に対するパターンマッチングは、成功するという 1 つの結果しか得られないため、特に簡単です。

網羅性（カバレッジ）チェック  
パターンチェックの選択肢が失敗する可能性がある場合、`switch` 式全体が失敗する可能性があるかどうかを調べることが重要になります。もし式全体が失敗すると、プログラムの実行が特定の入力に対してトラップされる可能性があり、運用上の脅威となります。このため、コンパイラは被検査体がカバーされている形状（shape）かを追跡することで、パターンマッチングの網羅性をチェックします。コンパイラはカバーされていない被検査体に対して警告を発します（Motoko はマッチしない被検査体の有用な例も構築します）。網羅性チェックの便利な副産物は、決してマッチしない無効（dead）の選択肢を特定して警告することです。

まとめると、パターンチェックはいくつかのユースケースを持つ優れたツールです。パターンを静的に解析することで、コンパイラは未処理のケースや到達不可能なコードを指摘し、プログラマを支援します。これらはどちらもプログラマのエラーを示すことが多いです。カバレッジチェックは静的でコンパイル時に行われるため、ランタイムにおける失敗を確実に排除することができます。

<!--

# Pattern matching

Pattern matching is a language feature that makes it easy to both test and decompose structured data into its constituent parts. While most programming languages provide familiar ways to build structured data, pattern matching enables you to take apart structured data and bring its fragments into scope by binding them to the names you specify. Syntactically, the patterns resemble the construction of structured data, but generally appear in input-direction positions, such as in function argument positions, after the `case` keyword in `switch` expressions, and after `let` or `var` declarations.

Consider the following function call:

``` motoko include=fullname
let name : Text = fullName({ first = "Jane"; mid = "M"; last = "Doe" });
```

This code constructs a record with three fields and passes it to the function `fullName`. The result of the call is named and brought into scope by binding it to the identifier `name`. The last, binding step is called pattern matching, and `name : Text` is one of the simplest forms of pattern. For instance, in the following implementation of the callee:

``` motoko name=fullname
func fullName({ first : Text; mid : Text; last : Text }) : Text {
  first # " " # mid # " " # last
};
```

The input is an (anonymous) object, which is destructured into its three `Text` fields, whose values are bound to the identifiers `first`, `mid` and `last`. They can be freely used in the block that forms the body of the function. Above we have resorted to *name punning* (a form of aliasing) for object field patterns, using the name of a field to also name its contents. A more general form of field pattern allows the content to be named separately from the field, as in `…​; mid = m : Text; …​`. Here `mid` determines which field to match, and `m` names the content of that field within the scope of the pattern.

You can also use pattern matching to declare *literal patterns*, which look just like literal constants. Literal patterns are especially useful in `switch` expressions because they can cause the current pattern match to *fail*, and thus start to match the next pattern. For example:

``` motoko
switch ("Adrienne", #female) {
  case (name, #female) { name # " is a girl!" };
  case (name, #male) { name # " is a boy!" };
  case (name, _) { name # ", is a human!" };
}
```

1.  will match the first `case` clause (because binding to the identifier `name` cannot fail and the shorthand variant literal `#Female` compares as equal), and evaluate to `"Adrienne is a girl!"`. The last clause showcases the *wildcard* pattern `_`. It cannot fail, but won’t bind any identifier.

The last kind of pattern is the `or` pattern. As its name suggests, these are two or more patterns that are separated by the keyword `or`. Each of the sub-patterns must bind to the same set of identifiers, and is matched from left-to-right. An `or` pattern fails when its rightmost sub-pattern fails.

| pattern kind               | example(s)                      | context    | can fail                              | remarks                                  |
|----------------------------|---------------------------------|------------|---------------------------------------|------------------------------------------|
| literal                    | `null`, `42`, `()`, `"Hi"`      | everywhere | when the type has more than one value |                                          |
| named                      | `age`, `x`                      | everywhere | no                                    | introduces identifiers into a new scope  |
| wildcard                   | `_`                             | everywhere | no                                    |                                          |
| typed                      | `age : Nat`                     | everywhere | conditional                           |                                          |
| option                     | `?0`, `?val`                    | everywhere | yes                                   |                                          |
| tuple                      | `( component0, component1, …​ )` | everywhere | conditional                           | must have at least two components        |
| object                     | `{ fieldA; fieldB; …​ }`         | everywhere | conditional                           | allowed to mention a subset of fields    |
| field                      | `age`, `count = 0`              | object     | conditional                           | `age` is short for `age = age`           |
| variant                    | `#celsius deg`, `#sunday`       | everywhere | yes                                   | `#sunday` is short form for `#sunday ()` |
| alternative (`or`-pattern) | `0 or 1`                        | everywhere | depends                               | no alternative may bind an identifier    |

The following table summarises the different ways of pattern matching.

## Additional information about about patterns

Since pattern matching has a rich history and interesting mechanics, a few additional comments are justified.

terminology
The (usually structured) expression that is being matched is frequently called the *scrutinee* and the patterns appearing behind the keyword `case` are the *alternatives*. When every possible scrutinee is matched by (at least one) alternative, then we say that the scrutinee is *covered*. The patterns are tried in top-down fashion and thus in case of *overlapping* patterns the one higher-up is selected. An alternative is considered *dead* (or *inactive*), if for every value that it matches there is higher-up alternative that is also matched.

booleans
The data type `Bool` can be regarded as two disjointed altenatives (`true` and `false`) and Motoko’s built-in `if` construct will *eliminate* the data and turn it into *control* flow. `if` expressions are a form of pattern matching that abbreviates the general `switch` expression for the special case of boolean scrutinees.

variant patterns
Motoko’s variant types are a form of *disjoint union* (sometimes also called a *sum type*). A value of variant type always has exactly one *discriminator* and a payload which can vary from discriminator to discriminator. When matching a variant pattern with a variant value, the discriminators must be the same (in order to select the alternative) and if so, the payload gets exposed for further matching.

enumerated types
Other programming languages — for example C, but not Motoko — often use a keyword `enum` to introduce enumerations. These are impoverished relatives of Motoko’s variant types, as the alternatives are not allowed to carry any payload. Correspondingly, in those languages the `switch`-like statements lack the full power of pattern matching. Motoko provides the short-hand syntax (as in `type Weekday = { #mon; #tue; …​ }`) to define basic enumerations, for which no payloads are required.

error handling
Error handling can be considered a use-case for pattern matching. When a function returns a value that has an alternative for success and one for failure (for example, an option value or a variant), pattern matching can be used to distinguish between the two as discussed in [Error handling](errors.md).

irrefutable matching
Some types contain just a single value. We call these *singleton types*. Examples of these are the unit type (also known as an empty tuple) or tuples of singleton types. Variants with a single tag and no (or singleton-typed) payload are singleton types too. Pattern matching on singleton types is particularly straightforward, as it only has one possible outcome: a successful match.

exhaustiveness (coverage) checking
When a pattern check alternative has the potential to fail, then it becomes important to find out whether the whole `switch` expression can fail. If this can happen the execution of the program can trap for certain inputs, posing an operational threat. To this end, the compiler checks for the exhaustiveness of pattern matching by keeping track of the covered shape of the scrutinee. The compiler issues a warning for any non-covered scrutinees (Motoko even constructs a helpful example of a scrutinee that is not matched). A useful by-product of the exhaustiveness check is that it identifies and warns about dead alternatives that can never be matched.

In summary, pattern checking is a great tool with several use-cases. By statically analyzing patterns, the compiler assists the programmer by pointing out unhandled cases and unreachable code, both of which often indicate programmer error. The static, compile-time nature of coverage checking reliably rules out runtime failures.

-->
