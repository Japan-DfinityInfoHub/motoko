# データと挙動の共有

Motoko では、ミュータブルなステートは常にプライベートであることを思い出してください。

しかしながら、2 つの Actor はメッセージによってデータを共有することができ、それらのメッセージは自分自身とお互いを含む Actor を参照することができます。 さらに、`shared` 関数であれば、メッセージが個々の関数を参照することが可能です。

これらのメカニズムにより、2 つの Actor は非同期のメッセージパッシングによって挙動を協調させることができます。

## Actor による出版-購読型（Publisher-subscriber）パターン

この章の例では、 [出版-購読型パターン](https://en.wikipedia.org/wiki/Publish-subscribe_pattern) のいくつかの例に焦点を当て、Actor がどのように関数を共有するかを説明します。 出版-購読型パターンでは、**出版する（publishing）** Actor は、**購読する（subscriber）** Actor のリストを記録して、出版者のステートに何らかの変化があった際に通知します。 例えば、出版者の Actor が新しい記事を発行すると、購読者の Actor に対して新たな記事があることが通知されます。

以下は 2 つの Actor を使って Motoko で出版-購読型の関係を構築する例を示します。

このパターンを使用するプロジェクトの全体のコードを見るには、[サンプルリポジトリ](https://github.com/dfinity/examples) の [pubsub](https://github.com/dfinity/examples/tree/master/motoko/pubsub) をご覧ください。

### 購読者（Subscriber） Actor

以下の `Subscriber` Actor の型は、出版者 Actor から呼び出すことができるように購読者 Actor が公開しているインターフェースです。

```motoko name=tsub
type Subscriber = actor {
  notify : () -> ()
};
```

- `Publisher` はこの型を、購読者をデータとして保持するデータ構造を定義するために使います。

- それぞれの `Subscriber` Actor は、上の例で型シグネチャが示しているように、更新用の関数である `notify` を公開しています。

サブタイピングによって、`Subscriber` Actor は上の型定義で示されていない追加のメソッドを含むことが可能であることに注意してください。

問題を単純にするため、`notify` 関数は関連する通知データを受け取り、購読者に関する何らかの新しいステータスメッセージを出版者に返すことにしましょう。 例えば、購読者は通知されるデータに基づき、購読に関する設定の変更を返すかもしれません。

### 出版者（Publisher） Actor

出版者側は購読者の配列を持ちます。 問題を単純にするため、それぞれの購読者は `subscribe` 関数を用いて一度だけ購読できるものとしましょう。

```motoko name=pub include=tsub
import Array "mo:base/Array";

actor Publisher {
    var subs: [Subscriber] = [];

    public func subscribe(sub: Subscriber) {
        subs := Array.append<Subscriber>(subs, [sub]);
    };

    public func publish() {
        for (sub in subs.vals()) {
          sub.notify();
        };
    };
};
```

その後、ある外部のエージェント（agent）が `publish` 関数を呼び出すと、上で述べた `Subscriber` 型で定義されている `notify` メッセージをすべての購読者が受け取ります。

### 購読者メソッド

最も単純なケースでは、購読者 Actor は以下のメソッドを持ちます。

- `init` メソッドを用いて出版者からの通知を購読する。

- 購読者 Actor の一人として、上記 `Subscriber` 型の `notify` 関数で指定された通知を受け取る。

- 蓄積したステートに対する問い合わせを許可する。このサンプルコードでは受け取った通知の数を保存する `count` 変数に対する `get` メソッドがそれに該当する。

次のコードは、これらのメソッドを実装した例です。

```motoko include=tsub,pub
actor Subscriber {
  var count: Nat = 0;
  public func init() {
    Publisher.subscribe(Subscriber);
  };
  public func notify() {
    count += 1;
  };
  public func get() : async Nat {
    count
  };
}
```

この Actor は `init` 関数が一度だけ呼ばれることを想定していますが、強制はしていません。 この `init` 関数では、`Subscriber` Actor は自分自身への参照を `actor { notify : () → () };` 型で渡します（ここでは上の `Subscriber` を呼んでいます）。

もし複数回呼ばれた場合、Actor は自分自身を複数回購読することになり、出版者から複数の（重複した）通知を受信することになります。 この脆弱性は、上で示した基本的な出版-購読型パターンの設計の結果です。 より注意深く設計された、より高度な出版者であれば、例えば購読者の重複をチェックして無視することでしょう。

## Actor 間の関数の共有

Motoko では、`shared` Actor 関数はメッセージで他の Actor に送ることができ、後で自分自身や他の Actor から呼び出すことができます。

上に示したコードは説明のために単純化されています。 完全なコードでは出版者と購読者の関係に対してさらなる機能が提供されており、この関係をより柔軟なものにするために shared 関数が用いられています。

例えば、上のコードでは通知用の関数は _常に_ `notify` と名付けられています。 より柔軟な設計としては、`notify` の型だけを固定しておき、購読者 Actor そのものを渡す代わりに `subscribe` メッセージで指定する `shared` 関数を購読者が選択できるようにすることが考えられます。

詳しくは、[完全なコード例](https://github.com/dfinity/examples/tree/master/motoko/pub-sub) をご覧ください。

特に、購読者がそのインターフェースの特定の命名規則に縛られることを避けたいとします。 本当に重要なのは、購読者が選んだ _ある_ 関数を発行者が呼び出せるかどうかです。

### `shared` キーワード

この柔軟性を実現するために、Actor は単なる自分自身への参照ではなく、他の Actor からのリモート呼び出しを可能にする一つの _関数_ を共有する必要があります。

関数を共有するには、あらかじめ `shared` と指定する必要があり、型システムはこれらの関数の引数の型、返り値の型、クロージャが包む（close over）データ型が、特定のルールに従うことを強制しています。

Motoko では、_public_ な Actor メソッドに対して shared キーワードを省略することができます。なぜなら、暗黙のうちに（明示的にマークされているかどうかにかかわらず）_Actor のパブリック関数は `shared` でなければならない_ からです。

`shared` 関数型を使用すると、上記の例をより柔軟に拡張することができます。 例えば、以下のようにします。

```motoko name=submessage
type SubscribeMessage = { callback: shared () -> (); };
```

これは元の Subscribe 型とは異なり、`callback` という単一のフィールドを持つ _メッセージ_ のレコード型を記述しており、最初に示したオリジナルの型は `notify` という単一のメソッドを持つ _Actor_ 型を記述しています。

```motoko name=typesub
type Subscriber = actor { notify : () -> () };
```

注目すべきなのは、`actor` キーワードが意味するのは、この型はフィールドを持つ通常のレコードではなく、少なくとも 1 つのメソッドがあり、そのメソッドは `notify` という名前で _なければならない_ ということです。

代わりに `SubscribeMessage` 型を使用することで、`Subscriber` Actor は `notify` メソッドに別の名前を指定することができます。

```motoko name=newsub include=submessage,newpub
actor Subscriber {
  var count: Nat = 0;
  public func init() {
    Publisher.subscribe({callback = incr;});
  };
  public func incr() {
    count += 1;
  };
  public query func get(): async Nat {
    count
  };
};
```

元のバージョンと比較すると、唯一変わっている行は `notify` の名前を `incr` に変更し、`{callback = incr}` 式を用いて新しい `subscribe` メッセージのペイロードを形成している部分です。

同様に、出版者も対応するインターフェイスを持つように更新することが出来ます。

```motoko name=newpub include=submessage
import Array "mo:base/Array";
actor Publisher {
  var subs: [SubscribeMessage] = [];
  public func subscribe(sub: SubscribeMessage) {
    subs := Array.append<SubscribeMessage>(subs, [sub]);
  };
  public func publish() {
    for (sub in subs.vals()) {
      sub.callback();
    };
  };
};
```

<!--

# Sharing data and behavior

Recall that in Motoko, mutable state is always private to an actor.

However, two actors can share message data, and those messages can refer to actors, including themselves and one another. Additionally, messages can refer to individual functions, if those functions are `shared`.

Through these mechanisms, two actors can coordinate their behavior through asynchronous message passing.

## Publisher-subscriber pattern with actors

The examples in this section illustrate how actors share their functions by focusing on variations of the [publish-subscribe pattern](https://en.wikipedia.org/wiki/Publish-subscribe_pattern). In the publish-subscribe pattern, a **publishing** actor records a list of **subscriber** actors to notify when something notable occurs in the publisher’s state. For example, if the publisher actor publishes a new article, the subscriber actors are notified that a new article is available.

The example below uses two actors in Motoko to build variations of the publisher-subscriber relationship.

To see the complete code for a working project that uses this pattern, see the [pubsub](https://github.com/dfinity/examples/tree/master/motoko/pubsub) example in the [examples repository](https://github.com/dfinity/examples).

### Subscriber actor

The following `Subscriber` actor type provides a possible interface for the subscriber actor and the publisher actor to expose and to call, respectively:

``` motoko name=tsub
type Subscriber = actor {
  notify : () -> ()
};
```

-   The `Publisher` uses this type to define a data structure to store its subscribers as data.

-   Each `Subscriber` actor exposes a `notify` update function as described in the `Subscriber` actor type signature above.

Note that sub-typing enables the `Subscriber` actor to include additional methods that are not listed in this type definition.

For simplicity, assume that the `notify` function accepts relevant notification data and returns some new status message about the subscriber to the publisher. For example, the subscriber might return a change to its subscription settings based on the notification data.

### Publisher actor

The publisher side of the code stores an array of subscribers. For simplicity, assume that each subscriber only subscribes itself once using a `subscribe` function.

``` motoko name=pub include=tsub
import Array "mo:base/Array";

actor Publisher {
    var subs: [Subscriber] = [];

    public func subscribe(sub: Subscriber) {
        subs := Array.append<Subscriber>(subs, [sub]);
    };

    public func publish() {
        for (sub in subs.vals()) {
          sub.notify();
        };
    };
};
```

Later, when some unspecified external agent invokes the `publish` function, all of the subscribers receive the `notify` message, as defined in the `Subscriber` type given above.

### Subscriber methods

In the simplest case, the subscriber actor has the following methods:

-   Subscribe to notifications from the publisher using the `init` method.

-   Receive notification as one of the subscribed actors as specified by the `notify` function in the `Subscriber` type given above).

-   Permit queries to the accumulated state, which in this sample code is simply a `get` method for the number of notifications received and stored in the `count` variable.

The following code illustrates implementing these methods:

``` motoko include=tsub,pub
actor Subscriber {
  var count: Nat = 0;
  public func init() {
    Publisher.subscribe(Subscriber);
  };
  public func notify() {
    count += 1;
  };
  public func get() : async Nat {
    count
  };
}
```

The actor assumes, but does not enforce, that its `init` function is only ever called once. In the `init` function, the `Subscriber` actor passes a reference to itself, of type `actor { notify : () → () };` (locally called `Subscriber` above).

If called more than once, the actor will subscribe itself multiple times, and will receive multiple (duplicate) notifications from the publisher. This fragility is the consequence of the basic publisher-subscriber design we show above. With more care, a more advanced publisher actor could check for duplicate subscriber actors and ignore them, for instance.

## Sharing functions among actors

In Motoko, a `shared` actor function can be sent in a message to another actor, and then later called by that actor, or by another actor.

The code shown above has been simplified for illustrative purposes. The full version offers additional features to the publisher-subscriber relationship, and uses shared functions to make this relationship more flexible.

For instance, the notification function is *always* designated as `notify`. A more flexible design would only fix the type of `notify`, and permit the subscriber to choose any of its `shared` functions, specified in a `subscribe` message in place of (just) the actor that is subscribing.

See the [the full example](https://github.com/dfinity/examples/tree/master/motoko/pub-sub) for details.

In particular, suppose that the subscriber wants to avoid being locked into a certain naming scheme for its interface. What really matters is that the publisher can call *some* function that the subscriber chooses.

### The `shared` keyword

To permit this flexibility, an actor needs to share a single *function* that permits remote invocation from another actor, not merely a reference to itself.

The ability to share a function requires that it be pre-designated as `shared`, and the type system enforces that these functions follow certain rules around the types of data that these functions accept, return, and over which their closures close.

Motoko lets you omit this keyword for *public* actor methods since, implicitly, *any public function of an actor must be \`shared\`*, whether marked explicitly or not.

Using the `shared` function type, we can extend the example above to be more flexible. For example:

``` motoko name=submessage
type SubscribeMessage = { callback: shared () -> (); };
```

This type differs from the original, in that it describes *a message* record type with a single field called `callback`, and the original type first shown above describes *an actor* type with a single method called `notify`:

``` motoko name=typesub
type Subscriber = actor { notify : () -> () };
```

Notably, the `actor` keyword means that this latter type is not an ordinary record with fields, but rather, an actor with at least one method, which *must* be called `notify`.

By using the `SubscribeMessage` type instead, the `Subscriber` actor can choose another name for their `notify` method:

``` motoko name=newsub include=submessage,newpub
actor Subscriber {
  var count: Nat = 0;
  public func init() {
    Publisher.subscribe({callback = incr;});
  };
  public func incr() {
    count += 1;
  };
  public query func get(): async Nat {
    count
  };
};
```

Compared to the original version, the only lines that change are those that rename `notify` to `incr`, and form the new `subscribe` message payload, using the expression `{callback = incr}`.

Likewise, we can update the publisher to have a matching interface:

``` motoko name=newpub include=submessage
import Array "mo:base/Array";
actor Publisher {
  var subs: [SubscribeMessage] = [];
  public func subscribe(sub: SubscribeMessage) {
    subs := Array.append<SubscribeMessage>(subs, [sub]);
  };
  public func publish() {
    for (sub in subs.vals()) {
      sub.callback();
    };
  };
};
```

-->
