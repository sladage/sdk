// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../common.dart';
import '../common/backend_api.dart' show
    ForeignResolver;
import '../common/resolution.dart' show
    Parsing,
    Resolution;
import '../compiler.dart' show
    Compiler;
import '../constants/values.dart';
import '../core_types.dart' show
    CoreTypes;
import '../dart_types.dart';
import '../elements/elements.dart';
import '../js/js.dart' as js;
import '../js_backend/js_backend.dart';
import '../tree/tree.dart';
import '../universe/side_effects.dart' show
    SideEffects;
import '../util/util.dart';

import 'enqueue.dart';
import 'js.dart';

/// This class is a temporary work-around until we get a more powerful DartType.
class SpecialType {
  final String name;
  const SpecialType._(this.name);

  /// The type Object, but no subtypes:
  static const JsObject = const SpecialType._('=Object');

  int get hashCode => name.hashCode;
}

/// Description of the exception behaviour of native code.
///
/// TODO(sra): Replace with something that better supports specialization on
/// first argument properties.
class NativeThrowBehavior {
  static const NativeThrowBehavior NEVER = const NativeThrowBehavior._(0);
  static const NativeThrowBehavior MAY_THROW_ONLY_ON_FIRST_ARGUMENT_ACCESS =
      const NativeThrowBehavior._(1);
  static const NativeThrowBehavior MAY = const NativeThrowBehavior._(2);
  static const NativeThrowBehavior MUST = const NativeThrowBehavior._(3);

  final int _bits;
  const NativeThrowBehavior._(this._bits);

  bool get canThrow => this != NEVER;

  /// Does this behavior always throw a noSuchMethod check on a null first
  /// argument before any side effect or other exception?
  // TODO(sra): Extend NativeThrowBehavior with the concept of NSM guard
  // followed by other potential behavior.
  bool get isNullNSMGuard => this == MAY_THROW_ONLY_ON_FIRST_ARGUMENT_ACCESS;

  /// Does this behavior always act as a null noSuchMethod check, and has no
  /// other throwing behavior?
  bool get isOnlyNullNSMGuard =>
      this == MAY_THROW_ONLY_ON_FIRST_ARGUMENT_ACCESS;

  /// Returns the behavior if we assume the first argument is not null.
  NativeThrowBehavior get onNonNull {
    if (this == MAY_THROW_ONLY_ON_FIRST_ARGUMENT_ACCESS) return NEVER;
    return this;
  }

  String toString() {
    if (this == NEVER) return 'never';
    if (this == MAY) return 'may';
    if (this == MAY_THROW_ONLY_ON_FIRST_ARGUMENT_ACCESS) return 'null(1)';
    if (this == MUST) return 'must';
    return 'NativeThrowBehavior($_bits)';
  }
}

/**
 * A summary of the behavior of a native element.
 *
 * Native code can return values of one type and cause native subtypes of
 * another type to be instantiated.  By default, we compute both from the
 * declared type.
 *
 * A field might yield any native type that 'is' the field type.
 *
 * A method might create and return instances of native subclasses of its
 * declared return type, and a callback argument may be called with instances of
 * the callback parameter type (e.g. Event).
 *
 * If there is one or more `@Creates` annotations, the union of the named types
 * replaces the inferred instantiated type, and the return type is ignored for
 * the purpose of inferring instantiated types.
 *
 *     @Creates('IDBCursor')    // Created asynchronously.
 *     @Creates('IDBRequest')   // Created synchronously (for return value).
 *     IDBRequest openCursor();
 *
 * If there is one or more `@Returns` annotations, the union of the named types
 * replaces the declared return type.
 *
 *     @Returns('IDBRequest')
 *     IDBRequest openCursor();
 *
 * Types in annotations are non-nullable, so include `@Returns('Null')` if
 * `null` may be returned.
 */
class NativeBehavior {

  /// [DartType]s or [SpecialType]s returned or yielded by the native element.
  final List typesReturned = [];

  /// [DartType]s or [SpecialType]s instantiated by the native element.
  final List typesInstantiated = [];

  // If this behavior is for a JS expression, [codeTemplate] contains the
  // parsed tree.
  js.Template codeTemplate;

  final SideEffects sideEffects = new SideEffects.empty();

  NativeThrowBehavior throwBehavior = NativeThrowBehavior.MAY;

  bool isAllocation = false;
  bool useGvn = false;

  // TODO(sra): Make NativeBehavior immutable so PURE and PURE_ALLOCATION can be
  // final constant-like objects.
  static NativeBehavior get PURE => NativeBehavior._makePure();
  static NativeBehavior get PURE_ALLOCATION =>
      NativeBehavior._makePure(isAllocation: true);
  static NativeBehavior get CHANGES_OTHER => NativeBehavior._makeChangesOther();
  static NativeBehavior get DEPENDS_OTHER => NativeBehavior._makeDependsOther();


  String toString() {
    return 'NativeBehavior('
        'returns: ${typesReturned}'
        ', creates: ${typesInstantiated}'
        ', sideEffects: ${sideEffects}'
        ', throws: ${throwBehavior}'
        '${isAllocation ? ", isAllocation" : ""}'
        '${useGvn ? ", useGvn" : ""}'
        ')';
  }

  static NativeBehavior _makePure({bool isAllocation: false}) {
    NativeBehavior behavior = new NativeBehavior();
    behavior.sideEffects.clearAllDependencies();
    behavior.sideEffects.clearAllSideEffects();
    behavior.throwBehavior = NativeThrowBehavior.NEVER;
    behavior.isAllocation = isAllocation;
    return behavior;
  }

  static NativeBehavior _makeChangesOther() {
    // TODO(25544): Have a distinct effect instead of using static properties to
    // model 'other' effects.
    return _makePure()..sideEffects.setChangesStaticProperty();
  }

  static NativeBehavior _makeDependsOther() {
    // TODO(25544): Have a distinct effect instead of using static properties to
    // model 'other' effects.
    return _makePure()..sideEffects.setDependsOnStaticPropertyStore();
  }

  /// Processes the type specification string of a call to JS and stores the
  /// result in the [typesReturned] and [typesInstantiated]. It furthermore
  /// computes the side effects, and, if given, invokes [setSideEffects] with
  /// the computed effects. If no side effects are encoded in the [specString]
  /// the [setSideEffects] method is not invoked.
  ///
  /// Two forms of the string is supported:
  ///
  /// 1) A single type string of the form 'void', '', 'var' or 'T1|...|Tn' which
  ///    defines the types returned, and, for the last form, the types also
  ///    created by the call to JS.  'var' (and '') are like 'dynamic' or
  ///    'Object' except that 'dynamic' would indicate that objects of any type
  ///    are created, which defeats tree-shaking.  Think of 'var' (and '') as
  ///    meaning 'any pre-existing type'.
  ///
  ///    The types Ti are non-nullable, so add class `Null` to specify a
  ///    nullable type, e.g `'String|Null'`.
  ///
  /// 2) A sequence of <tag>:<value> pairs of the following kinds
  ///
  ///        <type-tag>:<type-string>
  ///        <effect-tag>:<effect-string>
  ///        throws:<throws-string>
  ///        gvn:<gvn-string>
  ///        new:<new-string>
  ///
  ///    A <type-tag> is either 'returns' or 'creates' and <type-string> is a
  ///    type string like in 1). The type string marked by 'returns' defines the
  ///    types returned and 'creates' defines the types created by the call to
  ///    JS. If 'creates' is missing, it defaults to 'returns'.
  ///
  ///    An <effect-tag> is either 'effects' or 'depends' and <effect-string> is
  ///    either 'all', 'none' or a comma-separated list of 'no-index',
  ///    'no-instance', 'no-static'.
  ///
  ///    The flag 'all' indicates that the call affects/depends on every
  ///    side-effect. The flag 'none' indicates that the call does not affect
  ///    (resp. depends on) anything.
  ///
  ///    'no-index' indicates that the call does *not* do any array index-store
  ///    (for 'effects'), or depends on any value in an array (for 'depends').
  ///    The flag 'no-instance' indicates that the call does not modify (resp.
  ///    depends on) any instance variable. Similarly static variables are
  ///    indicated with 'no-static'. The flags 'effects' and 'depends' must be
  ///    used in unison (either both are present or none is).
  ///
  ///    The <throws-string> values are 'never', 'may', 'must', and 'null(1)'.
  ///    The default if unspecified is 'may'. 'null(1)' means that the template
  ///    expression throws if and only if the first template parameter is `null`
  ///    or `undefined`.
  ///    TODO(sra): Can we simplify to must/may/never and add null(1) by
  ///    inspection as an orthogonal attribute?
  ///
  ///    <gvn-string> values are 'true' and 'false'. The default if unspecified
  ///    is 'false'.
  ///
  ///    <new-string> values are 'true' and 'false'. The default if unspecified
  ///    is 'false'. A 'true' value means that each evaluation returns a fresh
  ///    (new) object that cannot be unaliased with existing objects.
  ///
  ///    Each tag kind (including the 'type-tag's) can only occur once in the
  ///    sequence.
  ///
  /// [specString] is the specification string, [resolveType] resolves named
  /// types into type values, [typesReturned] and [typesInstantiated] collects
  /// the types defined by the specification string, and [objectType] and
  /// [nullType] define the types for `Object` and `Null`, respectively. The
  /// latter is used for the type strings of the form '' and 'var'.
  /// [validTags] can be used to restrict which tags are accepted.
  static void processSpecString(
      DiagnosticReporter reporter,
      Spannable spannable,
      String specString,
      {Iterable<String> validTags,
       void setSideEffects(SideEffects newEffects),
       void setThrows(NativeThrowBehavior throwKind),
       void setIsAllocation(bool isAllocation),
       void setUseGvn(bool useGvn),
       dynamic resolveType(String typeString),
       List typesReturned,
       List typesInstantiated,
       objectType, nullType}) {


    bool seenError = false;

    void reportError(String message) {
      seenError = true;
      reporter.reportErrorMessage(
          spannable, MessageKind.GENERIC, {'text': message});
    }

    const List<String> knownTags = const [
          'creates', 'returns', 'depends', 'effects',
          'throws', 'gvn', 'new'];

    /// Resolve a type string of one of the three forms:
    /// *  'void' - in which case [onVoid] is called,
    /// *  '' or 'var' - in which case [onVar] is called,
    /// *  'T1|...|Tn' - in which case [onType] is called for each resolved Ti.
    void resolveTypesString(String typesString,
                            {onVoid(), onVar(), onType(type)}) {
      // Various things that are not in fact types.
      if (typesString == 'void') {
        if (onVoid != null) {
          onVoid();
        }
        return;
      }
      if (typesString == '' || typesString == 'var') {
        if (onVar != null) {
          onVar();
        }
        return;
      }
      for (final typeString in typesString.split('|')) {
        onType(resolveType(typeString.trim()));
      }
    }

    if (!specString.contains(';') && !specString.contains(':')) {
      // Form (1), types or pseudo-types like 'void' and 'var'.
      resolveTypesString(specString.trim(), onVar: () {
        typesReturned.add(objectType);
        typesReturned.add(nullType);
      }, onType: (type) {
        typesInstantiated.add(type);
        typesReturned.add(type);
      });
      return;
    }

    List<String> specs = specString.split(';')
        .map((s) => s.trim())
        .toList();
    if (specs.last == "") specs.removeLast();  // Allow separator to terminate.

    assert(validTags == null ||
           (validTags.toSet()..removeAll(validTags)).isEmpty);
    if (validTags == null) validTags = knownTags;

    Map<String, String> values = <String, String>{};

    for (String spec in specs) {
      List<String> tagAndValue = spec.split(':');
      if (tagAndValue.length != 2) {
        reportError("Invalid <tag>:<value> pair '$spec'.");
        continue;
      }
      String tag = tagAndValue[0].trim();
      String value = tagAndValue[1].trim();

      if (validTags.contains(tag)) {
        if (values[tag] == null) {
          values[tag] = value;
        } else {
          reportError("Duplicate tag '$tag'.");
        }
      } else {
        if (knownTags.contains(tag)) {
          reportError("Tag '$tag' is not valid here.");
        } else {
          reportError("Unknown tag '$tag'.");
        }
      }
    }

    // Enum-like tags are looked up in a map. True signature is:
    //
    //  T tagValueLookup<T>(String tag, Map<String, T> map);
    //
    dynamic tagValueLookup(String tag, Map<String, dynamic> map) {
      String tagString = values[tag];
      if (tagString == null) return null;
      var value = map[tagString];
      if (value == null) {
        reportError("Unknown '$tag' specification: '$tagString'.");
      }
      return value;
    }

    String returns = values['returns'];
    if (returns != null) {
      resolveTypesString(returns,
        onVar: () {
          typesReturned.add(objectType);
          typesReturned.add(nullType);
        },
        onType: (type) {
          typesReturned.add(type);
        });
    }

    String creates = values['creates'];
    if (creates != null) {
      resolveTypesString(creates,
        onVoid: () {
          reportError("Invalid type string 'creates:$creates'");
        },
        onType: (type) {
          typesInstantiated.add(type);
        });
    } else if (returns != null) {
      resolveTypesString(returns,
        onType: (type) {
          typesInstantiated.add(type);
        });
    }

    const throwsOption = const <String, NativeThrowBehavior>{
      'never': NativeThrowBehavior.NEVER,
      'null(1)': NativeThrowBehavior.MAY_THROW_ONLY_ON_FIRST_ARGUMENT_ACCESS,
      'may': NativeThrowBehavior.MAY,
      'must': NativeThrowBehavior.MUST };

    const boolOptions = const<String, bool>{'true': true, 'false': false};

    SideEffects sideEffects = processEffects(reportError,
        values['effects'], values['depends']);
    NativeThrowBehavior throwsKind = tagValueLookup('throws', throwsOption);
    bool isAllocation = tagValueLookup('new', boolOptions);
    bool useGvn = tagValueLookup('gvn', boolOptions);

    if (isAllocation == true && useGvn == true) {
      reportError("'new' and 'gvn' are incompatible");
    }

    if (seenError) return;  // Avoid callbacks.

    // TODO(sra): Simplify [throwBehavior] using [sideEffects].

    if (sideEffects != null) setSideEffects(sideEffects);
    if (throwsKind != null) setThrows(throwsKind);
    if (isAllocation != null) setIsAllocation(isAllocation);
    if (useGvn != null) setUseGvn(useGvn);
  }

  static SideEffects processEffects(
      void reportError(String message),
      String effects,
      String depends) {

    if (effects == null && depends == null) return null;

    if (effects == null || depends == null) {
      reportError("'effects' and 'depends' must occur together.");
      return null;
    }

    SideEffects sideEffects = new SideEffects();
    if (effects == "none") {
      sideEffects.clearAllSideEffects();
    } else if (effects == "all") {
      // Don't do anything.
    } else {
      List<String> splitEffects = effects.split(",");
      if (splitEffects.isEmpty) {
        reportError("Missing side-effect flag.");
      }
      for (String effect in splitEffects) {
        switch (effect) {
          case "no-index":
            sideEffects.clearChangesIndex();
            break;
          case "no-instance":
            sideEffects.clearChangesInstanceProperty();
            break;
          case "no-static":
            sideEffects.clearChangesStaticProperty();
            break;
          default:
            reportError("Unrecognized side-effect flag: '$effect'.");
        }
      }
    }

    if (depends == "none") {
      sideEffects.clearAllDependencies();
    } else if (depends == "all") {
      // Don't do anything.
    } else {
      List<String> splitDependencies = depends.split(",");
      if (splitDependencies.isEmpty) {
        reportError("Missing side-effect dependency flag.");
      }
      for (String dependency in splitDependencies) {
        switch (dependency) {
          case "no-index":
            sideEffects.clearDependsOnIndexStore();
            break;
          case "no-instance":
            sideEffects.clearDependsOnInstancePropertyStore();
            break;
          case "no-static":
            sideEffects.clearDependsOnStaticPropertyStore();
            break;
          default:
            reportError("Unrecognized side-effect flag: '$dependency'.");
        }
      }
    }

    return sideEffects;
  }

  static NativeBehavior ofJsCall(
      Send jsCall,
      DiagnosticReporter reporter,
      Parsing parsing,
      CoreTypes coreTypes,
      ForeignResolver resolver) {
    // The first argument of a JS-call is a string encoding various attributes
    // of the code.
    //
    //  'Type1|Type2'.  A union type.
    //  '=Object'.      A JavaScript Object, no subtype.

    NativeBehavior behavior = new NativeBehavior();

    var argNodes = jsCall.arguments;
    if (argNodes.isEmpty || argNodes.tail.isEmpty) {
      reporter.reportErrorMessage(
          jsCall,
          MessageKind.GENERIC,
          {'text': "JS expression takes two or more arguments."});
      return behavior;
    }

    var specArgument = argNodes.head;
    if (specArgument is !StringNode || specArgument.isInterpolation) {
      reporter.reportErrorMessage(
          specArgument, MessageKind.GENERIC,
          {'text': "JS first argument must be a string literal."});
      return behavior;
    }

    var codeArgument = argNodes.tail.head;
    if (codeArgument is !StringNode || codeArgument.isInterpolation) {
      reporter.reportErrorMessage(
          codeArgument, MessageKind.GENERIC,
          {'text': "JS second argument must be a string literal."});
      return behavior;
    }

    behavior.codeTemplate =
        js.js.parseForeignJS(codeArgument.dartString.slowToString());

    String specString = specArgument.dartString.slowToString();

    dynamic resolveType(String typeString) {
      return _parseType(
          typeString,
          parsing,
          (name) => resolver.resolveTypeFromString(specArgument, name),
          specArgument);
    }

    bool sideEffectsAreEncodedInSpecString = false;

    void setSideEffects(SideEffects newEffects) {
      sideEffectsAreEncodedInSpecString = true;
      behavior.sideEffects.setTo(newEffects);
    }

    bool throwBehaviorFromSpecString = false;
    void setThrows(NativeThrowBehavior throwBehavior) {
      throwBehaviorFromSpecString = true;
      behavior.throwBehavior = throwBehavior;
    }

    void setIsAllocation(bool isAllocation) {
      behavior.isAllocation = isAllocation;
    }

    void setUseGvn(bool useGvn) {
      behavior.useGvn = useGvn;
    }

    processSpecString(
        reporter,
        specArgument,
        specString,
        setSideEffects: setSideEffects,
        setThrows: setThrows,
        setIsAllocation: setIsAllocation,
        setUseGvn: setUseGvn,
        resolveType: resolveType,
        typesReturned: behavior.typesReturned,
        typesInstantiated: behavior.typesInstantiated,
        objectType: coreTypes.objectType,
        nullType: coreTypes.nullType);

    if (!sideEffectsAreEncodedInSpecString) {
      new SideEffectsVisitor(behavior.sideEffects)
          .visit(behavior.codeTemplate.ast);
    }
    if (!throwBehaviorFromSpecString) {
      behavior.throwBehavior =
          new ThrowBehaviorVisitor().analyze(behavior.codeTemplate.ast);
    }

    return behavior;
  }

  static void _fillNativeBehaviorOfBuiltinOrEmbeddedGlobal(
      NativeBehavior behavior,
      Send jsBuiltinOrEmbeddedGlobalCall,
      DiagnosticReporter reporter,
      Parsing parsing,
      CoreTypes coreTypes,
      ForeignResolver resolver,
      {bool isBuiltin,
       List<String> validTags}) {
    // The first argument of a JS-embedded global call is a string encoding
    // the type of the code.
    //
    //  'Type1|Type2'.  A union type.
    //  '=Object'.      A JavaScript Object, no subtype.

    String builtinOrGlobal = isBuiltin ? "builtin" : "embedded global";

    Link<Node> argNodes = jsBuiltinOrEmbeddedGlobalCall.arguments;
    if (argNodes.isEmpty) {
      reporter.internalError(jsBuiltinOrEmbeddedGlobalCall,
          "JS $builtinOrGlobal expression has no type.");
    }

    // We don't check the given name. That needs to be done at a later point.
    // This is, because we want to allow non-literals (like references to
    // enums) as names.
    if (argNodes.tail.isEmpty) {
      reporter.internalError(jsBuiltinOrEmbeddedGlobalCall,
          'JS $builtinOrGlobal is missing name.');
    }

    if (!isBuiltin) {
      if (!argNodes.tail.tail.isEmpty) {
        reporter.internalError(argNodes.tail.tail.head,
            'JS embedded global has more than 2 arguments');
      }
    }

    LiteralString specLiteral = argNodes.head.asLiteralString();
    if (specLiteral == null) {
      // TODO(sra): We could accept a type identifier? e.g. JS(bool, '1<2').  It
      // is not very satisfactory because it does not work for void, dynamic.
      reporter.internalError(argNodes.head, "Unexpected first argument.");
    }

    String specString = specLiteral.dartString.slowToString();

    dynamic resolveType(String typeString) {
      return _parseType(
          typeString,
          parsing,
          (name) => resolver.resolveTypeFromString(specLiteral, name),
          jsBuiltinOrEmbeddedGlobalCall);
    }

    void setSideEffects(SideEffects newEffects) {
      behavior.sideEffects.setTo(newEffects);
    }

    processSpecString(
        reporter,
        jsBuiltinOrEmbeddedGlobalCall,
        specString,
        validTags: validTags,
        resolveType: resolveType,
        setSideEffects: setSideEffects,
        typesReturned: behavior.typesReturned,
        typesInstantiated: behavior.typesInstantiated,
        objectType: coreTypes.objectType,
        nullType: coreTypes.nullType);
  }

  static NativeBehavior ofJsBuiltinCall(
      Send jsBuiltinCall,
      DiagnosticReporter reporter,
      Parsing parsing,
      CoreTypes coreTypes,
      ForeignResolver resolver) {
    NativeBehavior behavior = new NativeBehavior();
    behavior.sideEffects.setTo(new SideEffects());

    _fillNativeBehaviorOfBuiltinOrEmbeddedGlobal(
        behavior,
        jsBuiltinCall,
        reporter,
        parsing,
        coreTypes,
        resolver,
        isBuiltin: true);

    return behavior;
  }

  static NativeBehavior ofJsEmbeddedGlobalCall(
      Send jsEmbeddedGlobalCall,
      DiagnosticReporter reporter,
      Parsing parsing,
      CoreTypes coreTypes,
      ForeignResolver resolver) {
    NativeBehavior behavior = new NativeBehavior();
    // TODO(sra): Allow the use site to override these defaults.
    // Embedded globals are usually pre-computed data structures or JavaScript
    // functions that never change.
    behavior.sideEffects.setTo(new SideEffects.empty());
    behavior.throwBehavior = NativeThrowBehavior.NEVER;

    _fillNativeBehaviorOfBuiltinOrEmbeddedGlobal(
        behavior,
        jsEmbeddedGlobalCall,
        reporter,
        parsing,
        coreTypes,
        resolver,
        isBuiltin: false,
        validTags: const ['returns', 'creates']);

    return behavior;
  }

  static NativeBehavior ofMethod(FunctionElement method,  Compiler compiler) {
    FunctionType type = method.computeType(compiler.resolution);
    var behavior = new NativeBehavior();
    var returnType = type.returnType;
    bool isInterop = compiler.backend.isJsInterop(method);
    // Note: For dart:html and other internal libraries we maintain, we can
    // trust the return type and use it to limit what we enqueue. We have to
    // be more conservative about JS interop types and assume they can return
    // anything (unless the user provides the experimental flag to trust the
    // type of js-interop APIs). We do restrict the allocation effects and say
    // that interop calls create only interop types (which may be unsound if
    // an interop call returns a DOM type and declares a dynamic return type,
    // but otherwise we would include a lot of code by default).
    // TODO(sigmund,sra): consider doing something better for numeric types.
    behavior.typesReturned.add(
        !isInterop || compiler.trustJSInteropTypeAnnotations ? returnType
        : const DynamicType());
    if (!type.returnType.isVoid) {
      // Declared types are nullable.
      behavior.typesReturned.add(compiler.coreTypes.nullType);
    }
    behavior._capture(type, compiler.resolution,
        isInterop: isInterop, compiler: compiler);

    // TODO(sra): Optional arguments are currently missing from the
    // DartType. This should be fixed so the following work-around can be
    // removed.
    method.functionSignature.forEachOptionalParameter(
        (ParameterElement parameter) {
          behavior._escape(parameter.type, compiler.resolution);
        });

    behavior._overrideWithAnnotations(method, compiler);
    return behavior;
  }

  static NativeBehavior ofFieldLoad(MemberElement field, Compiler compiler) {
    Resolution resolution = compiler.resolution;
    DartType type = field.computeType(resolution);
    var behavior = new NativeBehavior();
    bool isInterop = compiler.backend.isJsInterop(field);
    // TODO(sigmund,sra): consider doing something better for numeric types.
    behavior.typesReturned.add(
        !isInterop || compiler.trustJSInteropTypeAnnotations ? type
        : const DynamicType());
    // Declared types are nullable.
    behavior.typesReturned.add(resolution.coreTypes.nullType);
    behavior._capture(type, resolution,
        isInterop: isInterop, compiler: compiler);
    behavior._overrideWithAnnotations(field, compiler);
    return behavior;
  }

  static NativeBehavior ofFieldStore(MemberElement field, Compiler compiler) {
    Resolution resolution = compiler.resolution;
    DartType type = field.computeType(resolution);
    var behavior = new NativeBehavior();
    behavior._escape(type, resolution);
    // We don't override the default behaviour - the annotations apply to
    // loading the field.
    return behavior;
  }

  void _overrideWithAnnotations(Element element, Compiler compiler) {
    if (element.implementation.metadata.isEmpty) return;

    DartType lookup(String name) {
      Element e = element.buildScope().lookup(name);
      if (e == null) return null;
      if (e is! ClassElement) return null;
      ClassElement cls = e;
      cls.ensureResolved(compiler.resolution);
      return cls.thisType;
    }

    NativeEnqueuer enqueuer = compiler.enqueuer.resolution.nativeEnqueuer;
    var creates = _collect(element, compiler, enqueuer.annotationCreatesClass,
                           lookup);
    var returns = _collect(element, compiler, enqueuer.annotationReturnsClass,
                           lookup);

    if (creates != null) {
      typesInstantiated..clear()..addAll(creates);
    }
    if (returns != null) {
      typesReturned..clear()..addAll(returns);
    }
  }

  /**
   * Returns a list of type constraints from the annotations of
   * [annotationClass].
   * Returns `null` if no constraints.
   */
  static _collect(Element element, Compiler compiler, Element annotationClass,
                  lookup(str)) {
    DiagnosticReporter reporter = compiler.reporter;
    var types = null;
    for (MetadataAnnotation annotation in element.implementation.metadata) {
      annotation.ensureResolved(compiler.resolution);
      ConstantValue value =
          compiler.constants.getConstantValue(annotation.constant);
      if (!value.isConstructedObject) continue;
      ConstructedConstantValue constructedObject = value;
      if (constructedObject.type.element != annotationClass) continue;

      Iterable<ConstantValue> fields = constructedObject.fields.values;
      // TODO(sra): Better validation of the constant.
      if (fields.length != 1 || !fields.single.isString) {
        reporter.internalError(annotation,
            'Annotations needs one string: ${annotation.node}');
      }
      StringConstantValue specStringConstant = fields.single;
      String specString = specStringConstant.toDartString().slowToString();
      for (final typeString in specString.split('|')) {
        var type = _parseType(typeString, compiler.parsing, lookup, annotation);
        if (types == null) types = [];
        types.add(type);
      }
    }
    return types;
  }

  /// Models the behavior of having intances of [type] escape from Dart code
  /// into native code.
  void _escape(DartType type, Resolution resolution) {
    type.computeUnaliased(resolution);
    type = type.unaliased;
    if (type is FunctionType) {
      FunctionType functionType = type;
      // A function might be called from native code, passing us novel
      // parameters.
      _escape(functionType.returnType, resolution);
      for (DartType parameter in functionType.parameterTypes) {
        _capture(parameter, resolution);
      }
    }
  }

  /// Models the behavior of Dart code receiving instances and methods of [type]
  /// from native code.  We usually start the analysis by capturing a native
  /// method that has been used.
  ///
  /// We assume that JS-interop APIs cannot instantiate Dart types or
  /// non-JSInterop native types.
  void _capture(DartType type, Resolution resolution,
      {bool isInterop: false, Compiler compiler}) {
    type.computeUnaliased(resolution);
    type = type.unaliased;
    if (type is FunctionType) {
      FunctionType functionType = type;
      _capture(functionType.returnType, resolution,
          isInterop: isInterop, compiler: compiler);
      for (DartType parameter in functionType.parameterTypes) {
        _escape(parameter, resolution);
      }
    } else {
      DartType instantiated = null;
      JavaScriptBackend backend = compiler?.backend;
      if (!isInterop) {
        typesInstantiated.add(type);
      } else {
        if (type.element != null && backend.isNative(type.element)) {
          // Any declared native or interop type (isNative implies isJsInterop)
          // is assumed to be allocated.
          typesInstantiated.add(type);
        }

        if (!compiler.trustJSInteropTypeAnnotations ||
          type.isDynamic || type.isObject) {
          // By saying that only JS-interop types can be created, we prevent
          // pulling in every other native type (e.g. all of dart:html) when a
          // JS interop API returns dynamic or when we don't trust the type
          // annotations. This means that to some degree we still use the return
          // type to decide whether to include native types, even if we don't
          // trust the type annotation.
          ClassElement cls = backend.helpers.jsJavaScriptObjectClass;
          cls.ensureResolved(resolution);
          typesInstantiated.add(cls.thisType);
        } else {
          // Otherwise, when the declared type is a Dart type, we do not
          // register an allocation because we assume it cannot be instantiated
          // from within the JS-interop code. It must have escaped from another
          // API.
        }
      }
    }
  }

  static dynamic _parseType(
      String typeString,
      Parsing parsing,
      lookup(name),
      locationNodeOrElement) {
    DiagnosticReporter reporter = parsing.reporter;
    if (typeString == '=Object') return SpecialType.JsObject;
    if (typeString == 'dynamic') {
      return const DynamicType();
    }
    var type = lookup(typeString);
    if (type != null) return type;

    int index = typeString.indexOf('<');
    if (index < 1) {
      reporter.reportErrorMessage(
          _errorNode(locationNodeOrElement, parsing),
          MessageKind.GENERIC,
          {'text': "Type '$typeString' not found."});
      return const DynamicType();
    }
    type = lookup(typeString.substring(0, index));
    if (type != null)  {
      // TODO(sra): Parse type parameters.
      return type;
    }
    reporter.reportErrorMessage(
        _errorNode(locationNodeOrElement, parsing),
        MessageKind.GENERIC,
        {'text': "Type '$typeString' not found."});
    return const DynamicType();
  }

  static _errorNode(locationNodeOrElement, Parsing parsing) {
    if (locationNodeOrElement is Node) return locationNodeOrElement;
    return locationNodeOrElement.parseNode(parsing);
  }
}
