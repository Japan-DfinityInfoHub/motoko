

class Bar () {
  
  private class Foo(f1:Int -> Int, f2:Int -> Int) { 
    private bomb = f1(666) + f2(666);
  };

  let Bar = Foo(g, g);

  private g(n:Int) : Int = n + 1;

}
