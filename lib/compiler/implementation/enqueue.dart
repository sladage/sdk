// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class EnqueueTask extends CompilerTask {
  final Enqueuer codegen;
  final Enqueuer resolution;

  String get name() => 'Enqueue';

  EnqueueTask(Compiler compiler)
    : codegen = new Enqueuer(compiler),
      resolution = new Enqueuer(compiler),
      super(compiler) {
    codegen.task = this;
    resolution.task = this;
  }
}

class Enqueuer {
  final Compiler compiler; // TODO(ahe): Remove this dependency.
  final Map<String, Link<Element>> instanceMembersByName;
  final Set<ClassElement> seenClasses;
  final Universe universe;
  final Queue<WorkItem> queue;
  bool queueIsClosed = false;
  EnqueueTask task;

  Enqueuer(this.compiler)
    : instanceMembersByName = new Map<String, Link<Element>>(),
      seenClasses = new Set<ClassElement>(),
      universe = new Universe(),
      queue = new Queue<WorkItem>();

  void addToWorkList(Element element, [TreeElements elements]) {
    if (queueIsClosed) {
      compiler.internalErrorOnElement(element, "Work list is closed.");
    }
    if (element.kind === ElementKind.GENERATIVE_CONSTRUCTOR) {
      registerInstantiatedClass(element.enclosingElement);
    }
    queue.add(new WorkItem(element, elements));
  }

  void registerInstantiatedClass(ClassElement cls) {
    universe.instantiatedClasses.add(cls);
    onRegisterInstantiatedClass(cls);
  }

  bool checkNoEnqueuedInvokedInstanceMethods() {
    task.measure(() {
      // Run through the classes and see if we need to compile methods.
      for (ClassElement classElement in universe.instantiatedClasses) {
        for (ClassElement currentClass = classElement;
             currentClass !== null;
             currentClass = currentClass.superclass) {
          processInstantiatedClass(currentClass);
        }
      }
    });
    return true;
  }

  void processInstantiatedClass(ClassElement cls) {
    cls.members.forEach(processInstantiatedClassMember);
  }

  void registerFieldClosureInvocations() {
    task.measure(() {
      // Make sure that the closure understands a call with the given
      // selector. For a method-invocation of the form o.foo(a: 499), we
      // need to make sure that closures can handle the optional argument if
      // there exists a field or getter 'foo'.
      var names = universe.instantiatedClassInstanceFields;
      // TODO(ahe): Might be enough to use invokedGetters.
      for (SourceString name in names) {
        Set<Selector> invokedSelectors = universe.invokedNames[name];
        if (invokedSelectors != null) {
          for (Selector selector in invokedSelectors) {
            registerDynamicInvocation(Namer.CLOSURE_INVOCATION_NAME, selector);
          }
        }
      }
    });
  }

  void processInstantiatedClassMember(Element member) {
    if (universe.generatedCode.containsKey(member)) return;

    if (!member.isInstanceMember()) return;
    if (member.isField()) return;

    String memberName = member.name.slowToString();
    Link<Element> members = instanceMembersByName.putIfAbsent(
        memberName, () => const EmptyLink<Element>());
    instanceMembersByName[memberName] = members.prepend(member);

    if (member.kind === ElementKind.GETTER ||
        member.kind === ElementKind.FIELD) {
      universe.instantiatedClassInstanceFields.add(member.name);
    }

    if (member.kind == ElementKind.FUNCTION) {
      if (member.name == Compiler.NO_SUCH_METHOD) {
        compiler.enableNoSuchMethod(member);
      }
      if (universe.hasInvocation(member, compiler)) {
        return addToWorkList(member);
      }
      // If there is a property access with the same name as a method we
      // need to emit the method.
      if (universe.hasGetter(member, compiler)) {
        // We will emit a closure, so make sure the closure class is
        // generated.
        compiler.closureClass.ensureResolved(compiler);
        registerInstantiatedClass(compiler.closureClass);
        return addToWorkList(member);
      }
    } else if (member.kind == ElementKind.GETTER) {
      if (universe.hasGetter(member, compiler)) {
        return addToWorkList(member);
      }
      // We don't know what selectors the returned closure accepts. If
      // the set contains any selector we have to assume that it matches.
      if (universe.hasInvocation(member, compiler)) {
        return addToWorkList(member);
      }
    } else if (member.kind === ElementKind.SETTER) {
      if (universe.hasSetter(member, compiler)) {
        return addToWorkList(member);
      }
    }
  }

  void onRegisterInstantiatedClass(ClassElement cls) {
    task.measure(() {
      while (cls !== null) {
        if (seenClasses.contains(cls)) return;
        seenClasses.add(cls);
        // TODO(ahe): Don't call resolveType, instead, call this method
        // when resolveType is called.
        compiler.resolveClass(cls);
        cls.members.forEach(processInstantiatedClassMember);
        cls = cls.superclass;
      }
    });
  }

  void registerNewSelector(SourceString name,
                           Selector selector,
                           Map<SourceString, Set<Selector>> selectorsMap) {
    Set<Selector> selectors =
        selectorsMap.putIfAbsent(name, () => new Set<Selector>());
    if (!selectors.contains(selector)) {
      selectors.add(selector);
      handleUnseenSelector(name, selector);
    }
  }

  void registerInvocation(SourceString methodName, Selector selector) {
    task.measure(() {
      registerNewSelector(methodName, selector, universe.invokedNames);
    });
  }

  void registerGetter(SourceString getterName, Selector selector) {
    task.measure(() {
      registerNewSelector(getterName, selector, universe.invokedGetters);
    });
  }

  void registerSetter(SourceString setterName, Selector selector) {
    task.measure(() {
      registerNewSelector(setterName, selector, universe.invokedSetters);
    });
  }

  processInstanceMembers(SourceString n, bool f(Element e)) {
    String memberName = n.slowToString();
    Link<Element> members = instanceMembersByName[memberName];
    if (members !== null) {
      LinkBuilder<Element> remaining = new LinkBuilder<Element>();
      for (; !members.isEmpty(); members = members.tail) {
        if (!f(members.head)) remaining.addLast(members.head);
      }
      instanceMembersByName[memberName] = remaining.toLink();
    }
  }

  void handleUnseenSelector(SourceString methodName, Selector selector) {
    processInstanceMembers(methodName, (Element member) {
      if (selector.applies(member, compiler)) {
        addToWorkList(member);
        return true;
      }
      return false;
    });
  }

  void registerStaticUse(Element element) {
    addToWorkList(element);
  }

  void registerGetOfStaticFunction(FunctionElement element) {
    registerStaticUse(element);
    universe.staticFunctionsNeedingGetter.add(element);
  }

  void registerDynamicInvocation(SourceString methodName, Selector selector) {
    assert(selector !== null);
    registerInvocation(methodName, selector);
  }

  void registerDynamicInvocationOf(Element element) {
    addToWorkList(element);
  }

  void registerDynamicGetter(SourceString methodName, Selector selector) {
    registerGetter(methodName, selector);
  }

  void registerDynamicSetter(SourceString methodName, Selector selector) {
    registerSetter(methodName, selector);
  }

  // TODO(ngeoffray): This should get a type.
  void registerIsCheck(Element element) {
    universe.isChecks.add(element);
  }
}