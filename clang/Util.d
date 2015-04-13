/**
 * Copyright: Copyright (c) 2011 Jacob Carlborg. All rights reserved.
 * Authors: Jacob Carlborg
 * Version: Initial created: Oct 1, 2011
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 */
module clang.Util;

import clang.c.index;
import clang.c.cxstring;

import std.conv;

immutable(char*)* strToCArray(string[] arr) {
    import std.string : toStringz;

    if (!arr)
        return null;

    immutable(char*)[] cArr;
    cArr.reserve(arr.length);

    foreach (str; arr)
        cArr ~= str.toStringz;

    return cArr.ptr;
}

string toD(CXString cxString) {
    auto cstr = clang_getCString(cxString);
    auto str = to!(string)(cstr).idup;
    clang_disposeString(cxString);

    return str;
}

template isCX(T) {
    enum bool isCX = __traits(hasMember, T, "cx");
}

template cxName(T) {
    enum cxName = "CX" ~ T.stringof;
}

U* toCArray(U, T)(T[] arr) {
    if (!arr)
        return null;

    static if (is(typeof(T.init.cx)))
        return arr.map!(e => e.cx).toArray.ptr;

    else
        return arr.ptr;
}

mixin template CX() {
    mixin("private alias " ~ cxName!(typeof(this)) ~ " CType;");

    CType cx;
    alias cx this;

    void dispose() {
        enum methodCall = "clang_dispose" ~ typeof(this).stringof ~ "(cx);";

        static if (false && __traits(compiles, methodCall))
            mixin(methodCall);
    }

    @property bool isValid() {
        return cx !is CType.init;
    }
}
