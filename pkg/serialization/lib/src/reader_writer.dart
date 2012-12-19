// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of serialization;

/**
 * This writes out the state of the objects to an external format. It holds
 * all of the intermediate state needed. The primary API for it is the
 * [write] method.
 */
// TODO(alanknight): For simple serialization formats this does a lot of work
// that isn't necessary, e.g. detecting cycles and maintaining references.
// Consider having an abstract superclass with the basic functionality and
// simple serialization subclasses where we know there aren't cycles.
class Writer {
  /**
   * The [serialization] holds onto the rules that define how objects
   * are serialized.
   */
  final Serialization serialization;

  /** The [trace] object keeps track of the objects to be visited while finding
   * the full set of objects to be written.*/
  Trace trace;

  /**
   * When we write out objects, should we also write out a description
   * of the rules for the serialization. This defaults to the corresponding
   * value on the Serialization.
   */
  bool selfDescribing;

  /**
   * Objects that cannot be represented in-place in the serialized form need
   * to have references to them stored. The [Reference] objects are computed
   * once and stored here for each object. This provides some space-saving,
   * but also serves to record which objects we have already seen.
   */
  final Map<Object, Reference> references =
      new IdentityMapPlus<Object, Reference>();

  /**
   * The state of objects that need to be serialized is stored here.
   * Each rule has a number, and rules keep track of the objects that they
   * serialize, in order. So the state of any object can be found by indexing
   * from the rule number and the object number within the rule.
   * The actual representation of the state is determined by the rule. Lists
   * and Maps are common, but it is arbitrary.
   */
  final List<List> states = new List<List>();

  /** Return the list of rules we use. */
  List<SerializationRule> get rules => serialization.rules;

  /**
   * Creates a new [Writer] that uses the rules from its parent
   * [Serialization]. Serializations are do not keep any state
   * related to a particular read/write, so the same one can be used
   * for multiple different Readers/Writers.
   */
  Writer(this.serialization) {
    trace = new Trace(this);
    selfDescribing = serialization.selfDescribing;
  }

  /**
   * This is the main API for a [Writer]. It writes the objects and returns
   * the serialized representation, currently a JSON format of a map
   * whose data is either lists indexed by field position or maps indexed
   * by field name, and holding either primitives or references. See [toMaps]
   */
  // TODO(alanknight): Generalize the output representation. Probably requires
  // introducing some sort of OutputFormat object.
  String write(anObject) {
    trace.addRoot(anObject);
    trace.traceAll();
    _flatten();
    return toStringFormat();
  }

  /**
   * This is an alternate writing API that writes the objects and returns
   * the serialized representation as a List of simple objects.
   * See [toFlatFormat].
   */
  List writeFlat(anObject) {
    shouldUseReferencesForPrimitives = true;
    trace.addRoot(anObject);
    trace.traceAll();
    _flatten();
    return toFlatFormat();
  }

  /**
   * Write to a simple flat format. This format is at the proof of concept
   * stage, so details are not finalized and are likely to change in the future.
   * Right now this produces a List containing null, int, and String. This is
   * more space-efficient than the map format created by [toStringFormat] or
   * [toMaps], but is much less human-readable.
   */
  List toFlatFormat() {
    var result = new List(3);
    // TODO(alanknight): Don't make it call toMaps in order to make non-maps.
    // As part of that, if writing flat, the rule serialization should be flat.
    var stuff = toMaps();
    result[0] = stuff["rules"];
    var roots = new List();
    stuff["roots"].forEach((x) => x.writeToList(roots));
    result[2] = roots;

    // TODO(alanknight): This needs serious generalization. Do we introduce
    // an output format object that the rules talk to? Do we make use of the
    // fact that rules talk to something that looks to them like a List. Do
    // we then mandate that instead of saying they have complete charge of
    // their own storage?
    var flatData = [];
    for (var eachRule in rules) {
      var ruleData = stuff["data"][eachRule.number];
      flatData.add(ruleData.length);
      eachRule.dumpStateInto(ruleData, flatData);
    }
    result[1] = flatData;
    return result;
  }

  /**
   * Given that we have fully populated the list of [states], and more
   * importantly, the list of [references], go through each state and turn
   * anything that requires a [Reference] into one. Since only the rules
   * know the representation they use for state, delegate to them.
   */
  void _flatten() {
    for (var eachRule in rules) {
      _growStates(eachRule);
      var index = eachRule.number;
      for (var eachState in states[index]) {
        eachRule.flatten(eachState, this);
      }
    }
  }

  /**
   * As the [trace] processes each object, it will call this method on us.
   * We find the rules for this object, and record the state of the object
   * as determined by each rule.
   */
  void _process(object, Trace trace) {
    var real = (object is DesignatedRuleForObject) ? object.target : object;
    for (var eachRule in serialization.rulesFor(object)) {
      _record(real, eachRule);
    }
  }

  /**
   * Record the state of [object] as determined by [rule] and keep
   * track of it. Generate a [Reference] for this object if required.
   * When it's required is up to the particular rule, but generally everything
   * gets a reference except a primitive.
   * Note that at this point the states are just the same as the fields of the
   * object, and haven't been flattened.
   */
  void _record(Object object, SerializationRule rule) {
    if (rule.shouldUseReferenceFor(object, this)) {
      references.putIfAbsent(object, () =>
          new Reference(this, rule.number, _nextObjectNumberFor(rule)));
      var state = rule.extractState(object, trace.note);
      _addStateForRule(rule, state);
    }
  }

  /**
   * Should we store primitive objects directly or create references for them.
   * That depends on which format we're using, so a flat format will want
   * references, but the Map format can store them directly.
   */
  bool shouldUseReferencesForPrimitives = false;

  /** Record a [state] entry for a particular rule. */
  void _addStateForRule(eachRule, Object state) {
    _growStates(eachRule);
    states[eachRule.number].add(state);
  }

  /** Find what the object number for the thing we're about to add will be.*/
  int _nextObjectNumberFor(SerializationRule rule) {
    _growStates(rule);
    return states[rule.number].length;
  }

  /**
   * We store the states in a List, indexed by rule number. But rules can be
   * dynamically added, so we may have to grow the list.
   */
  void _growStates(eachRule) {
    while (states.length <= eachRule.number) states.add(new List());
  }

  /**
   * Return true if we have an object number for this object. This is used to
   * tell if we have processed the object or not. This relies on checking if we
   * have a reference or not. That saves some space by not having to keep track
   * of simple objects, but means that if someone refers to the identical string
   * from several places, we will process it several times, and store it
   * several times. That seems an acceptable tradeoff, and in cases where it
   * isn't, it's possible to apply a rule for String, or even for Strings larger
   * than x, which gives them references.
   */
  bool _hasIndexFor(Object object) {
    return _objectNumberFor(object) != -1;
  }

  /**
   * Given an object, find what number it has. The number is valid only in
   * the context of a particular rule, and if the rule has more than one,
   * this will return the one for the primary rule, defined as the one that
   * is listed in its canonical reference.
   */
  int _objectNumberFor(Object object) {
    var reference = references[object];
    return (reference == null) ? -1 : reference.objectNumber;
  }

  /**
   * Return the serialized data in string format. Currently hard-coded to
   * our custom JSON format.
   */
  String toStringFormat() {
    return JSON.stringify(toMaps());
  }

  /**
   * Returns the full serialized structure as nested maps. The top-level
   * has 3 fields, "rules" which may hold a definition of the rules used,
   * "data" which holds the serialized data, and "roots", which holds
   * [Reference] objects indicating the root objects. Note that roots are
   * necessary because the data is organized in the same way as the object
   * structure, it's a list of lists holding self-contained maps which only
   * refer to other parts via [Reference] objects.
   * This effectively defines a custom JSON serialization format, although
   * the details of the format vary depending which rules were used.
   */
  Map toMaps() {
    var result = new Map();
    var savedRules;
    if (selfDescribing) {
      var meta = serialization._ruleSerialization();
      var writer = new Writer(meta);
      writer.selfDescribing = false;
      savedRules = writer.write(serialization.rules);
    }
    result["rules"] = savedRules;
    result["data"] = states;
    result["roots"] = _rootReferences(trace.roots);
    return result;
  }

  /**
   * Return a list of [Reference] objects pointing to our roots. This will be
   * stored in the output under "roots" in the default format.
   */
  _rootReferences(roots) =>
    roots.map(_referenceFor);

  /**
   * Given an object, return a reference for it if one exists. If there's
   * no reference, return null. Once we have finished the tracing step, all
   * objects that should have a reference (roughly speaking, non-primitives)
   * can be relied on to have a reference.
   */
  _referenceFor(Object o) {
    return references[o];
  }

  // For debugging/testing purposes. Find what state a reference points to.
  stateForReference(Reference r) =>
      states[r.ruleNumber][r.objectNumber];
}

/**
 * The main class responsible for reading. It holds
 * onto the necessary state and to the objects that have been inflated.
 */
class Reader {

  /**
   * The serialization that specifies how we read. Note that in contrast
   * to the Writer, this is not final. This is because we may be created
   * with an empty [Serialization] and then read the rules from the data,
   * if [selfDescribing] is true.
   */
  Serialization serialization;

  /**
   * When we read objects, should we read a description of the rules if
   * present. This defaults to the corresponding value on the Serialization.
   */
  bool selfDescribing;

  /**
   * The state of objects that have been serialized is stored here.
   * Each rule has a number, and rules keep track of the objects that they
   * serialize, in order. So the state of any object can be found by indexing
   * from the rule number and the object number within the rule.
   * The actual representation of the state is determined by the rule. Lists
   * and Maps are common, but it is arbitrary. See [Writer.states].
   */
  List<List> _data;

  /**
   * The resulting objects, indexed according to the same scheme as
   * [data], where each rule has a number, and rules keep track of the objects
   * that they serialize, in order.
   */
  List<List> objects;

  /**
   * Creates a new [Reader] that uses the rules from its parent
   * [Serialization]. Serializations do not keep any state related to
   * a particular read or write operation, so the same one can be used
   * for multiple different Writers/Readers.
   */
  Reader(this.serialization) {
    selfDescribing = serialization.selfDescribing;
  }

  /**
   * When we read, we may need to look up objects by name in order to link to
   * them. This is particularly true if we have references to classes,
   * functions, mirrors, or other non-portable entities. The map in which we
   * look things up can be provided as an argument to read, but we can also
   * provide a map here, and objects will be looked up in both places.
   */
  Map externalObjects;

  /**
   * Look up the reference to an external object. This can be held either in
   * the reader-specific list of externals or in the serializer's
   */
  externalObjectNamed(key) {
    var map = (externalObjects.containsKey(key))
        ? externalObjects : serialization.externalObjects;
    if (!map.containsKey(key)) {
      throw 'Cannot find named object to link to: $key';
    }
    return map[key];
  }

  /**
   * Return the list of rules to be used when writing. These come from the
   * [serialization].
   */
  List<SerializationRule> get rules => serialization.rules;

  /**
   * Internal use only, for testing purposes. Set the data for this reader
   * to a List of Lists whose size must match the number of rules.
   */
  // When we set the data, initialize the object storage to a matching size.
  void set data(List<List> newData) {
    _data = newData;
    objects = _data.map((x) => new List(x.length));
  }

  /**
   * This is the primary method for a [Reader]. It takes the input data,
   * currently hard-coded to expect our custom JSON format, and returns
   * the root objects.
   */
  read(String input, [Map externals = const {}]) {
    externalObjects = externals;
    var topLevel = JSON.parse(input);
    var ruleString = topLevel["rules"];
    readRules(ruleString, externals);
    data = topLevel["data"];
    rules.forEach(inflateForRule);
    var roots = topLevel["roots"];
    return roots.map(inflateReference);
  }

  /**
   * If the data we are reading from has rules written to it, read them back
   * and set them as the rules we will use.
   */
  void readRules(String newRules, Map externals) {
    // TODO(alanknight): Replacing the serialization is kind of confusing.
    List rulesWeRead = (newRules == null) ?
        null : serialization._ruleSerialization().readOne(newRules, externals);
    if (rulesWeRead != null && !rulesWeRead.isEmpty) {
      serialization = new Serialization.blank();
      rulesWeRead.forEach(serialization.addRule);
    }
  }

  /**
   * This is a hard-coded read method for a vaguely flat format. It's just a
   * proof of concept of handling more flat formats right now, and needs a lot
   * of fixing and generalization.
   */
  readFlat(List input, [Map externals = const {}]) {
    // TODO(alanknight): Way too much code duplication with read. Numerous
    // code smells.
    externalObjects = externals;
    var topLevel = input;
    var ruleString = topLevel[0];
    readRules(ruleString, externals);
    var flatData = topLevel[1];
    var stream = flatData.iterator();
    var tempData = new List(rules.length);
     for (var eachRule in rules) {
       tempData[eachRule.number] = eachRule.pullStateFrom(stream);
    }
    data = tempData;
    for (var eachRule in rules) {
      inflateForRule(eachRule);
    }
    var rootsAsInts = topLevel[2];
    var rootStream = rootsAsInts.iterator();
    var roots = new List();
    while (rootStream.hasNext) {
      roots.add(new Reference(this, rootStream.next(), rootStream.next()));
    }
    var x = inflateReference(roots[0]);
    return roots.map((x) => inflateReference(x));
  }


  /**
   * A convenient alternative to [read] when you know there is only
   * one object.
   */
  readOne(String input, [Map externals = const {}]) =>
      read(input, externals).first;

  /**
   * A convenient alternative to [readFlat] when you know there is only
   * one object.
   */
  readOneFlat(List input, [Map externals = const {}]) =>
      readFlat(input, externals).first;

  /**
   * Inflate all of the objects for [rule]. Does the essential state for all
   * objects first, then the non-essential state. This avoids cycles in
   * non-essential state, because all the objects will have already been
   * created.
   */
  inflateForRule(rule) {
    var dataForThisRule = _data[rule.number];
    keysAndValues(dataForThisRule).forEach((position, state) {
      inflateOne(rule, position, state);
    });
    keysAndValues(dataForThisRule).forEach((position, state) {
      rule.inflateNonEssential(state, allObjectsForRule(rule)[position], this);
    });
  }

  /**
   * Create a new object, based on [rule] and [state], which will
   * be stored in [position] in the storage for [rule]. This will
   * follow references and recursively inflate them, leaving Sentinel objects
   * to detect cycles.
   */
  Object inflateOne(SerializationRule rule, position, state) {
    var existing = allObjectsForRule(rule)[position];
    // We may already be in progress and hitting this in a cycle.
    if (existing is _Sentinel) {
      throw new SerializationException('Cycle in essential state');
    }
    // We may have already inflated this object, at least its essential state.
    if (existing != null) return existing;

    // Put a sentinel there to mark this in case of recursion.
    allObjectsForRule(rule)[position] = const _Sentinel();
    var newObject = rule.inflateEssential(state, this);
    allObjectsForRule(rule)[position] = newObject;
    return newObject;
  }

  /**
   * The parameter [possibleReference] might be a reference. If it isn't, just
   * return it. If it is, then inflate the target of the reference and return
   * the resulting object.
   */
  Object inflateReference(possibleReference) {
    // If this is a primitive, return it directly.
    // TODO This seems too complicated.
    return asReference(possibleReference,
        ifReference: (reference) {
          var rule = ruleFor(reference);
          var state = _stateFor(reference);
          inflateOne(rule, reference.objectNumber, state);
          return _objectFor(reference);
        });
  }

  /**
   * Given [reference], return what we have stored as an object for it. Note
   * that, depending on the current state, this might be null or a Sentinel.
   */
  Object _objectFor(Reference reference) =>
      objects[reference.ruleNumber][reference.objectNumber];

  /** Given [rule], return the storage for its objects. */
  allObjectsForRule(SerializationRule rule) => objects[rule.number];

  /** Given [reference], return the the state we have stored for it. */
  Object _stateFor(Reference reference) =>
      _data[reference.ruleNumber][reference.objectNumber];

  /** Given a reference, return the rule it references. */
  SerializationRule ruleFor(Reference reference) =>
      serialization.rules[reference.ruleNumber];

  /**
   * Given a possible reference [anObject], call either [ifReference] or
   * [ifNotReference], depending if it's a reference or not. This is the
   * primary place that knows about the serialized representation of a
   * reference.
   */
  asReference(anObject, {Function ifReference: doNothing,
      Function ifNotReference : doNothing}) {
    if (anObject is Reference) return ifReference(anObject);
    if (anObject is Map && anObject["__Ref"] == true) {
      var ref =
          new Reference(this, anObject["rule"], anObject["object"]);
      return ifReference(ref);
    } else {
      return ifNotReference(anObject);
    }
  }
}

/**
 * This serves as a marker to indicate a object that is in the process of
 * being de-serialized. So if we look for an object slot and find one of these,
 * we know we've hit a cycle.
 */
class _Sentinel {
  const _Sentinel();
}

/**
 * This represents the transitive closure of the referenced objects to be
 * used for serialization. It works closely in conjunction with the Writer,
 * and is kept as a separate object primarily for the possibility of wanting
 * to plug in different sorts of tracing rules.
 */
class Trace {
  // TODO(alanknight): It seems likely that the mechanism for cutting off
  // tracings is by specifying rules. So is there any reason any more to have
  // this as a separate class?
  final Writer writer;

  /**
   * This class works by doing a breadth-first traversal of the objects,
   * with the traversal order maintained in [queue].
   */
  final Queue queue = new Queue();

  /** The root objects from which we will be tracing. */
  List roots = [];

  Trace(this.writer);

  addRoot(object) {
    roots.add(object);
  }

  /** A convenience method to add a single root and trace it in one step. */
  trace(Object o) {
    addRoot(o);
    traceAll();
  }

  /**
   * Process all of the objects reachable from our roots via state that the
   * serialization rules access.
   */
  traceAll() {
    queue.addAll(roots);
    while (!queue.isEmpty) {
      var next = queue.removeFirst();
      if (!hasProcessed(next)) writer._process(next, this);
    }
  }

  /**
   * Has this object been seen yet? We test for this by checking if the
   * writer has a reference for it. See comment for _hasIndexFor.
   */
  bool hasProcessed(object) {
   return writer._hasIndexFor(object);
  }

  /** Note that we've seen [value], and add it to the queue to be processed. */
  note(Object value) {
    if (value != null) {
      queue.add(value);
    }
    return value;
  }
}

/**
 * Any pointers to objects that can't be represented directly in the
 * serialization format has to be stored as a reference. A reference encodes
 * the rule number of the rule that saved it in the Serialization that was used
 * for writing, and the object number within that rule.
 */
class Reference {
  /** The [Reader] or [Writer] that owns this reference. */
  final parent;
  /** The position of the rule that controls this reference in [parent]. */
  final int ruleNumber;
  /** The index of the referred-to object in the storage of [parent] */
  final int objectNumber;

  const Reference(this.parent, this.ruleNumber, this.objectNumber);

  /**
   * Convert the reference to a map in JSON format. This is specific to the
   * custom JSON format we define, and must be consistent with the
   * [asReference] method.
   */
  // TODO(alanknight): This is a hack both in defining a toJson specific to a
  // particular representation, and the use of a bogus sentinel "__Ref"
  toJson() => {
    "__Ref" : true,
    "rule" : ruleNumber,
    "object" : objectNumber
  };

  /** Write our information to [list]. Useful in writing to flat formats.*/
  writeToList(List list) {
    list.add(ruleNumber);
    list.add(objectNumber);
  }
}

/**
 * This is used during tracing to indicate that an object should be processed
 * using a particular rule, rather than the one that might ordinarily be
 * found for it. This normally only makes sense if the object is uniquely
 * referenced, and is a more or less internal collection. See ListRuleEssential
 * for an example. It knows how to return its object and how to filter.
 */
class DesignatedRuleForObject {
  Function rulePredicate;
  final target;

  DesignatedRuleForObject(this.target, this.rulePredicate);

  possibleRules(List rules) => rules.filter(rulePredicate);
}
