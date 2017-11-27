// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "core_patch.dart";

// NOTE: When making changes to this class, please also update
// `VmTarget.instantiateInvocation` and `VmTarget._invocationType` in
// `pkg/kernel/lib/target/vm.dart`.
class _InvocationMirror implements Invocation {
  // Constants describing the invocation kind.
  // _FIELD cannot be generated by regular invocation mirrors.
  static const int _METHOD = 0;
  static const int _GETTER = 1;
  static const int _SETTER = 2;
  static const int _FIELD = 3;
  static const int _LOCAL_VAR = 4;
  static const int _KIND_SHIFT = 0;
  static const int _KIND_BITS = 3;
  static const int _KIND_MASK = (1 << _KIND_BITS) - 1;

  // These values, except _DYNAMIC and _SUPER, are only used when throwing
  // NoSuchMethodError for compile-time resolution failures.
  static const int _DYNAMIC = 0;
  static const int _SUPER = 1;
  static const int _STATIC = 2;
  static const int _CONSTRUCTOR = 3;
  static const int _TOP_LEVEL = 4;
  static const int _LEVEL_SHIFT = _KIND_BITS;
  static const int _LEVEL_BITS = 3;
  static const int _LEVEL_MASK = (1 << _LEVEL_BITS) - 1;

  // ArgumentsDescriptor layout. Keep in sync with enum in dart_entry.h.
  static const int _TYPE_ARGS_LEN = 0;
  static const int _COUNT = 1;
  static const int _POSITIONAL_COUNT = 2;
  static const int _FIRST_NAMED_ENTRY = 3;

  // Internal representation of the invocation mirror.
  final String _functionName;
  final List _argumentsDescriptor;
  final List _arguments;
  final bool _isSuperInvocation;

  // External representation of the invocation mirror; populated on demand.
  Symbol _memberName;
  int _type;
  List<Type> _typeArguments;
  List _positionalArguments;
  Map<Symbol, dynamic> _namedArguments;

  _InvocationMirror._withType(this._memberName, this._type, this._typeArguments,
      this._positionalArguments, this._namedArguments) {
    _typeArguments ??= const <Type>[];
    _positionalArguments ??= const [];
    _namedArguments ??= const {};
  }

  void _setMemberNameAndType() {
    if (_functionName.startsWith("get:")) {
      _type = _GETTER;
      _memberName = new internal.Symbol.unvalidated(_functionName.substring(4));
    } else if (_functionName.startsWith("set:")) {
      _type = _SETTER;
      _memberName =
          new internal.Symbol.unvalidated(_functionName.substring(4) + "=");
    } else {
      _type = _isSuperInvocation ? (_SUPER << _LEVEL_SHIFT) | _METHOD : _METHOD;
      _memberName = new internal.Symbol.unvalidated(_functionName);
    }
  }

  Symbol get memberName {
    if (_memberName == null) {
      _setMemberNameAndType();
    }
    return _memberName;
  }

  List<Type> get typeArguments {
    if (_typeArguments == null) {
      int typeArgsLen =
          _decodeTypeArgsLenEntry(_argumentsDescriptor[_TYPE_ARGS_LEN]);
      if (typeArgsLen == 0) {
        return _typeArguments = const <Type>[];
      }
      // A TypeArguments object does not have a corresponding Dart class and
      // cannot be accessed as an array in Dart. Therefore, we need a native
      // call to unpack the individual types into a list.
      _typeArguments = _unpackTypeArguments(_arguments[0]);
    }
    return _typeArguments;
  }

  // Unpack the given TypeArguments object into a new list of individual types.
  static List<Type> _unpackTypeArguments(typeArguments)
      native "InvocationMirror_unpackTypeArguments";

  // Extract the compressed representation of the number of positional arguments
  // from the corresponding entry in the 'ArgumentsDescriptor'.
  static int _decodePositionalCountEntry(positionalCountEntry)
      native "InvocationMirror_decodePositionalCountEntry";

  // Extract the compressed representation of the number of type arguments
  // from the corresponding entry in the 'ArgumentsDescriptor'.
  static int _decodeTypeArgsLenEntry(typeArgsLenEntry)
      native "InvocationMirror_decodeTypeArgsLenEntry";

  List get positionalArguments {
    if (_positionalArguments == null) {
      // The argument descriptor counts the receiver, but not the type arguments
      // as positional arguments.
      int numPositionalArguments =
          _decodePositionalCountEntry(_argumentsDescriptor[_POSITIONAL_COUNT]) -
              1;
      if (numPositionalArguments == 0) {
        return _positionalArguments = const [];
      }
      // Exclude receiver and type args in the returned list.
      int receiverIndex =
          _decodeTypeArgsLenEntry(_argumentsDescriptor[_TYPE_ARGS_LEN]) > 0
              ? 1
              : 0;
      _positionalArguments = new _ImmutableList._from(
          _arguments, receiverIndex + 1, numPositionalArguments);
    }
    return _positionalArguments;
  }

  // Extract the position of a named argument from the corresponding entry in
  // the 'ArgumentsDescriptor'.
  static int _decodePositionEntry(positionEntry)
      native "InvocationMirror_decodePositionEntry";

  Map<Symbol, dynamic> get namedArguments {
    if (_namedArguments == null) {
      int numArguments = _argumentsDescriptor[_COUNT] - 1; // Exclude receiver.
      int numPositionalArguments =
          _decodePositionalCountEntry(_argumentsDescriptor[_POSITIONAL_COUNT]) -
              1;
      int numNamedArguments = numArguments - numPositionalArguments;
      if (numNamedArguments == 0) {
        return _namedArguments = const {};
      }
      int receiverIndex =
          _decodeTypeArgsLenEntry(_argumentsDescriptor[_TYPE_ARGS_LEN]) > 0
              ? 1
              : 0;
      _namedArguments = new Map<Symbol, dynamic>();
      for (int i = 0; i < numNamedArguments; i++) {
        int namedEntryIndex = _FIRST_NAMED_ENTRY + 2 * i;
        String arg_name = _argumentsDescriptor[namedEntryIndex];
        var arg_value = _arguments[receiverIndex +
            _decodePositionEntry(_argumentsDescriptor[namedEntryIndex + 1])];
        _namedArguments[new internal.Symbol.unvalidated(arg_name)] = arg_value;
      }
      _namedArguments = new Map.unmodifiable(_namedArguments);
    }
    return _namedArguments;
  }

  bool get isMethod {
    if (_type == null) {
      _setMemberNameAndType();
    }
    return (_type & _KIND_MASK) == _METHOD;
  }

  bool get isAccessor {
    if (_type == null) {
      _setMemberNameAndType();
    }
    return (_type & _KIND_MASK) != _METHOD;
  }

  bool get isGetter {
    if (_type == null) {
      _setMemberNameAndType();
    }
    return (_type & _KIND_MASK) == _GETTER;
  }

  bool get isSetter {
    if (_type == null) {
      _setMemberNameAndType();
    }
    return (_type & _KIND_MASK) == _SETTER;
  }

  _InvocationMirror(this._functionName, this._argumentsDescriptor,
      this._arguments, this._isSuperInvocation);

  _InvocationMirror._withoutType(this._functionName, this._typeArguments,
      this._positionalArguments, this._namedArguments, this._isSuperInvocation);

  static _allocateInvocationMirror(String functionName,
      List argumentsDescriptor, List arguments, bool isSuperInvocation) {
    return new _InvocationMirror(
        functionName, argumentsDescriptor, arguments, isSuperInvocation);
  }
}
