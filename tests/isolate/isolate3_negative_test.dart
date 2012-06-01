// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Dart test program for testing that errors thrown from isolates are
// processed correctly and don't result in crashes.

#library('Isolate3NegativeTest');
#import('dart:isolate');
#import('../../lib/unittest/unittest.dart');

class TestClass {
  TestClass.named(num this.fld1) : fld2=fld1 {
    TestClass.i = 0;  // Should cause a compilation error.
  }
  num fld1;
  num fld2;
}

class Isolate3NegativeTest extends Isolate {
  Isolate3NegativeTest() : super();

  void main() {
    this.port.receive((ignored, replyTo) {
      var tmp = new TestClass.named(10);
      replyTo.send(tmp, null);
    });
  }
}

main() {
  test("child isolate compilation errors propagate correctly. ", () {
    void msg_callback(var message) {
      // This test is a negative test and should not complete successfully.
    }
    void spawn_callback(SendPort port) {
      port.call("foo").then(expectAsync(msg_callback));
    }
    new Isolate3NegativeTest().spawn().then(expectAsync(spawn_callback));
  });
}