<?hh // strict
// Copyright 2004-present Facebook. All Rights Reserved.

class C {
  public function f(int $i): void {}
}

function test(dynamic $d): void {
  $c = new C();
  (($d_) ==> $c->f($d_))($d);
}
