/*******************************************************************************
 * 
 */
module voile.misc;


import core.exception;
import std.traits, std.typetuple, std.variant;

/*******************************************************************************
 * 
 */
auto ref assumeAttr(alias fn, alias attrs, Args...)(auto ref Args args)
if (isFunction!fn)
{
	alias Func = SetFunctionAttributes!(typeof(&fn), functionLinkage!fn, attrs);
//	if (!__ctfe)
//	{
//		alias dgTy = SetFunctionAttributes!(void function(string), "D", attrs);
//		debug { (cast(dgTy)&disp)(typeof(fn).stringof); }
//	}
	return (cast(Func)&fn)(args);
}

/// ditto
auto ref assumeAttr(alias fn, alias attrs, Args...)(auto ref Args args)
if (__traits(isTemplate, fn) && isCallable!(fn!Args))
{
	alias Func = SetFunctionAttributes!(typeof(&(fn!Args)), functionLinkage!(fn!Args), attrs);
//	if (!__ctfe)
//	{
//		alias dgTy = SetFunctionAttributes!(void function(string), "D", attrs);
//		debug { (cast(dgTy)&disp)(typeof(fn!Args).stringof); }
//	}
	return (cast(Func)&fn!Args)(args);
}

/// ditto
auto assumeAttr(alias attrs, Fn)(Fn t)
	if (isFunctionPointer!Fn || isDelegate!Fn)
{
	return cast(SetFunctionAttributes!(Fn, functionLinkage!Fn, attrs)) t;
}

/*******************************************************************************
 * 
 */
template getFunctionAttributes(T...)
{
	alias fn = T[0];
	static if (T.length == 1 && (isFunctionPointer!(T[0]) || isDelegate!(T[0])))
	{
		enum getFunctionAttributes = functionAttributes!fn;
	}
	else static if (!is(typeof(fn!(T[1..$]))))
	{
		enum getFunctionAttributes = functionAttributes!(fn);
	}
	else
	{
		enum getFunctionAttributes = functionAttributes!(fn!(T[1..$]));
	}
}

/*******************************************************************************
 * 
 */
auto ref assumePure(alias fn, Args...)(auto ref Args args)
{
	return assumeAttr!(fn, getFunctionAttributes!(fn, Args) | FunctionAttribute.pure_, Args)(args);
}

/// ditto
auto assumePure(T)(T t)
	if (isFunctionPointer!T || isDelegate!T)
{
	return assumeAttr!(getFunctionAttributes!T | FunctionAttribute.pure_)(t);
}

/*******************************************************************************
 * 
 */
auto ref assumeNogc(alias fn, Args...)(auto ref Args args)
{
	return assumeAttr!(fn, getFunctionAttributes!(fn, Args) | FunctionAttribute.nogc, Args)(args);
}

/// ditto
auto assumeNogc(T)(T t)
	if (isFunctionPointer!T || isDelegate!T)
{
	return assumeAttr!(getFunctionAttributes!T | FunctionAttribute.nogc)(t);
}


/*******************************************************************************
 * 
 */
auto ref assumeNothrow(alias fn, Args...)(auto ref Args args)
{
	return assumeAttr!(fn, getFunctionAttributes!(fn, Args) | FunctionAttribute.nothrow_, Args)(args);
}

/// ditto
auto assumeNothrow(T)(T t)
	if (isFunctionPointer!T || isDelegate!T)
{
	return assumeAttr!(getFunctionAttributes!T | FunctionAttribute.nothrow_)(t);
}



///
debug private void dispImpl(T...)(T args)
{
	import std.stdio, std.string;
	writeln(args);
}

///
debug void disp(T...)(T args) nothrow pure @nogc @trusted
{
	assumeAttr!(dispImpl!T, FunctionAttribute.nothrow_ | FunctionAttribute.pure_ | FunctionAttribute.nogc)(args);
}

private template AssumedUnsharedType(T)
{
	import std.traits;
	static if (is(T U == shared(U)))
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(U);
	}
	else static if (is(T U == const(shared(U))))
	{
		alias AssumedUnsharedType = const(AssumedUnsharedType!(U));
	}
	else static if (isPointer!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(pointerTarget!T)*;
	}
	else static if (isDynamicArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ForeachType!T)[];
	}
	else static if (isStaticArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ForeachType!T)[T.length];
	}
	else static if (isAssociativeArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ValueType!T)[AssumedUnsharedType!(KeyType!T)];
	}
	else
	{
		alias AssumedUnsharedType = T;
	}
}

/*******************************************************************************
 * 
 */
auto ref assumeUnshared(T)(ref T x) @property
{
	return *cast(AssumedUnsharedType!(T)*)&x;
}

/*******************************************************************************
 * 
 */
auto ref assumeShared(T)(ref T x) @property
{
	return *cast(shared)&x;
}


/*******************************************************************************
 * 
 */
template nogcEnforce(E : Throwable = Exception)
if (is(typeof(new E(string.init, __FILE__, __LINE__)) : Throwable)
 || is(typeof(new E(__FILE__, __LINE__)) : Throwable))
{
	T nogcEnforce(T)(T value, string msg = null, string file = __FILE__, size_t line = __LINE__) @safe @nogc
	if (is(typeof({ if (!value) {} })))
	{
		if (!value) (() @trusted => assumePure!(nogcBailOut!E)(file, line, msg))();
		return value;
	}
}
/// ditto
T nogcEnforce(T, Dg, string file = __FILE__, size_t line = __LINE__)(T value, scope Dg dg) @safe @nogc
if (isSomeFunction!Dg && is(typeof(dg())) && is(typeof(() { if (!value) { } } )))
{
	if (!value) dg();
}

private void nogcBailOut(E)(string file, size_t line, string msg) @safe @nogc
{
	import std.conv: emplace;
	static void[__traits(classInstanceSize, E)] _nogcExceptionBuffer;
	static if (is(typeof(new E(string.init, string.init, size_t.init))))
	{
		throw emplace!E((() @trusted => cast(E)(_nogcExceptionBuffer.ptr))(), msg, file, line);
	}
	else static if (is(typeof(new E(string.init, size_t.init))))
	{
		throw emplace!E((() @trusted => cast(E)(_nogcExceptionBuffer.ptr))(), file, line);
	}
	else static assert(0);
}

@safe @nogc unittest
{
	import std.exception;
	long x = 10;
	try nogcEnforce(x, "xxx");
	catch (Exception e) assert(0);
	
	x = 0;
	try nogcEnforce(x, "xxx");
	catch (Exception e)
	{
		x = 1;
	}
	assert(x == 1);
	
}

/*******************************************************************************
 * 
 */
template TemplateSpecializedTypeTuple(T)
{
	static if (is(T: Temp!Params, alias Temp, Params...))
	{
		alias TemplateSpecializedTypeTuple = Params;
	}
	else
	{
		enum NoneTemplate { init }
		alias TemplateSpecializedTypeTuple = TypeTuple!(NoneTemplate);
	}
}

private template _isNotRefPSC(uint pcs)
{
	enum _isNotRefPSC = (pcs & ParameterStorageClass.ref_) == 0;
}


/*******************************************************************************
 * 
 */
CommonType!(staticMap!(ReturnType, T))
	variantSwitch(T...)(auto ref Variant var, T caseFunctions)
{
	enum isZeroLengthParameter(P) = staticMap!(Parameters, P).length == 0;
	import core.exception;
	static assert(allSatisfy!(isCallable, T),
		"variantSwitch ascepts only callable");
	foreach (i, t1; T)
	{
		alias a1 = Parameters!(t1);
		alias r1 = ReturnType!(t1);
		
		static if (i + 1 < T.length)
		{
			// 最後のcase function以外では引数が1つでVariantというcaseは認められない
			static assert(a1.length != 1 || !is( a1[0] == Variant ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
		}
		foreach (t2; T[i+1 .. $] )
		{
			alias a2 = ParameterTypeTuple!(t2);
			alias psc2 = ParameterStorageClassTuple!(t2);
			static assert( !is( a1 == a2 ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
			static assert(a1.length);
			static if (a2.length)
			{
				static assert(!isImplicitlyConvertible!( a2, a1 ),
					"case function with argument types " ~ a2.stringof ~
					" is hidden by " ~ a1.stringof );
			}
			alias PSC = ParameterStorageClass;
			static if (!allSatisfy!(_isNotRefPSC, psc2))
			{
				alias psc = ParameterStorageClassTuple!(variantSwitch);
				static assert(psc[0] & PSC.ref_);
			}
		}
	}
	foreach (fn; caseFunctions)
	{
		alias Args = Parameters!fn;
		alias psc2 = ParameterStorageClassTuple!fn;
		static if (Args.length == 0)
		{
			return fn();
		}
		else static if (is(Args[0] == Variant))
		{
			return fn(var);
		}
		else
		{
			static if (allSatisfy!(_isNotRefPSC, psc2))
			{
				if (var.convertsTo!(typeof(Args.init)))
				{
					return fn(var.get!(typeof(Args.init)));
				}
			}
			else
			{
				if (var.convertsTo!(typeof(Args.init)))
				{
					auto v = var.get!(typeof(Args.init));
					scope (exit) var = v;
					return fn(v);
				}
			}
		}
	}
	static if (staticMap!(Parameters, T).length > 0
	 && !anySatisfy!(isZeroLengthParameter, T)
	 && !is(staticMap!(Parameters, T)[$-1] == Variant))
		throw new SwitchError("No appropriate switch clause found");
}


@system unittest
{
	Variant var1 = 1;
	Variant var2 = 3.5;
	Variant var3 = "test";
	
	void test(Variant v)
	{
		variantSwitch(v,
		(ubyte a)
		{
			assert(0);
		},
		(int a)
		{
			assert(a == 1);
		},
		(double a)
		{
			assert(a == 3.5);
		}
		);
	}
	test(var1);
	test(var2);
	
	
	auto test2(Variant v)
	{
		return variantSwitch(v,
		(ubyte a)
		{
			assert(a);
			return 0;
		},
		(int a)
		{
			assert(a == 1);
			return 1;
		},
		(double a)
		{
			assert(a == 3.5);
			return 2;
		}
		);
	}
	assert(test2(var1) == 1);
	assert(test2(var2) == 2);
	
	
	auto test3(Variant v)
	{
		return variantSwitch(v,
		(ubyte a)
		{
			assert(a);
			return 0;
		},
		(int a)
		{
			assert(a == 1);
			return 1;
		},
		(double a)
		{
			assert(a == 3.5);
			return 2;
		},
		(Variant a)
		{
			return 3;
		}
		);
	}
	try
	{
		test(var3);
		assert(0);
	}
	catch (SwitchError)
	{
	}
	catch (Throwable e)
	{
		assert(0);
	}
	assert(test3(var3) == 3);
	
	
	auto test4(ref Variant v)
	{
		int x;
		variantSwitch(v,
		(ref int a)
		{
			assert(a == 1);
			x = 0;
			a = 10;
		},
		()
		{
			x = 1;
		}
		);
		return x;
	}
	
	assert(var1 == 1);
	assert(test4(var1) == 0);
	assert(var1 == 10);
	assert(test4(var3) == 1);
	var1 = 1;
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		(ubyte a)
		{
		},
		// !
		(Variant a)
		{
		},
		(double a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		// !
		{
		},
		(int a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		(ubyte a)
		{
			return 0;
		},
		// !
		(ubyte a)
		{
			return 0;
		},
		{
			return 1;
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		(int a)
		{
			return 0;
		},
		// !
		(ubyte a)
		{
			return 0;
		},
		{
			return 1;
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(v,
		(ubyte a)
		{
			return 0;
		},
		// !
		{
			return 1;
		},
		(ubyte a)
		{
			return 0;
		}
		);
	}));
	
	
}



/*******************************************************************************
 * 
 */
deprecated("castSwitch is now available in Phobos std.algorithm")
CommonType!(staticMap!(ReturnType, T))
	castSwitch(Base, T...)(Base inst, T caseFunctions)
{
	static assert(allSatisfy!(isCallable, T),
		"classSwitch ascepts only callable");
	foreach (i, t1; T)
	{
		alias a1 = ParameterTypeTuple!(t1);
		alias r1 = ReturnType!(t1);
		
		static if (i+1 < T.length)
		{
			// 最後じゃなければBaseに暗黙変換可能な型のみが許される
			// 必ず引数は1つとること
			static assert(a1.length == 1
			          && isImplicitlyConvertible!( a1[0], Base ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
		}
		else
		{
			// 最後なら引数なしか、Baseに暗黙変換可能な型か、Baseが暗黙変換可能な型が許される
			static if (a1.length != 0)
			{
				static assert(isImplicitlyConvertible!( a1[0], Base )
				           || isImplicitlyConvertible!( Base, a1[0] ),
					"case function with argument types " ~ a1.stringof ~
					" occludes successive function");
			}
		}
		foreach (t2; T[i+1 .. $] )
		{
			alias a2 = ParameterTypeTuple!(t2);
			// 同じ型があってはならない
			static assert( !is( a1 == a2 ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
			static assert(a1.length);
			static if (a2.length)
			{
				// 引数があるなら、あとに書かれたcaseの型が先に書かれたcaseの型に暗黙変換不可能
				static assert(!isImplicitlyConvertible!( a2, a1 ),
					"case function with argument types " ~ a2.stringof ~
					" is hidden by " ~ a1.stringof );
			}
		}
	}
	foreach (fn; caseFunctions)
	{
		alias Args = ParameterTypeTuple!fn;
		static if (Args.length == 0)
		{
			return fn();
		}
		else static if (isImplicitlyConvertible!( Base, Args[0]))
		{
			return fn(inst);
		}
		else
		{
			if (auto casted = cast(Args[0])inst)
			{
				return fn(casted);
			}
		}
	}
	throw new SwitchError("No appropriate switch clause found");
}

version(none) @system unittest
{
	class A
	{
	}
	class B: A
	{
	}
	class C
	{
	}
	
	A a = new A;
	B b = new B;
	A a_b = new B;
	C c = new C;
	
	int test(Object o)
	{
		int x;
		castSwitch(o,
		(B a)
		{
			x = 0;
		},
		(A a)
		{
			x = 1;
		},
		(C a)
		{
			x = 2;
		}
		);
		return x;
	}
	assert(test(a) == 1);
	assert(test(b) == 0);
	assert(test(c) == 2);
	
	auto test2(Object o)
	{
		return castSwitch(o,
		(B a)
		{
			return 0;
		},
		(A a)
		{
			return 1;
		},
		(C a)
		{
			return 2;
		}
		);
	}
	assert(test2(a) == 1);
	assert(test2(b) == 0);
	assert(test2(c) == 2);
	
	
	class D
	{
	}
	D d = new D;
	auto test3(Object o)
	{
		return castSwitch(o,
		(B a)
		{
			return 0;
		},
		(A a)
		{
			return 1;
		},
		(C a)
		{
			return 2;
		},
		(Object a)
		{
			return 3;
		}
		);
	}
	try
	{
		test(d);
		assert(0);
	}
	catch (SwitchError)
	{
	}
	catch (Throwable e)
	{
		assert(0);
	}
	assert(test3(d) == 3);
	
	
	auto test4(Object o)
	{
		int x;
		castSwitch(o,
		(A a)
		{
			x = 0;
		},
		()
		{
			x = 1;
		}
		);
		return x;
	}
	
	assert(test4(a) == 0);
	assert(test4(d) == 1);
	
	static assert(!__traits(compiles,
	{
		caseSwitch(a,
		// !
		(A a)
		{
		},
		(B a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		caseSwitch(a,
		// !
		{
		},
		(A a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		caseSwitch(a,
		(B a)
		{
			return 0;
		},
		// !
		{
			return 1;
		},
		(C a)
		{
			return 0;
		}
		);
	}));
	
}


private S indentRuntime(S)(S s, S indentStr = " ")
{
	import std.array;
	auto app = appender!(S)();
	// Overflow is no problem for this line.
	app.reserve((s.length * 17)/16);
	
	immutable pend = s.ptr + s.length;
	auto p = s.ptr;
	auto pHead = p;
	
	void putLine()
	{
		assert(s.ptr <= pHead);
		assert(pHead <= p);
		assert(p <= pend);
		app.put(indentStr);
		app.put(pHead[0..p - pHead]);
		if (p !is pend)
		{
			pHead = p + 1;
		}
	}
	
	for (; p != pend; ++p)
	{
		if (*p == '\n')
		{
			putLine();
			app.put('\n');
		}
	}
	if (pHead != pend)
	{
		assert(p is pend);
		putLine();
	}
	return app.data;
}

private S indentCtfe(S)(S s, S indentStr = " ")
{
	import std.array, std.string;
	auto app = appender!(S)();
	
	auto lines = s.splitLines(KeepTerminator.yes);
	foreach (l; lines)
	{
		app.put(indentStr);
		app.put(l);
	}
	return app.data;
}


/*******************************************************************************
 * 
 */
S indent(S)(S s, S indentStr = "\t")
	out(r)
	{
		debug version(D_unittest)
		{
			assert(r == s.indentCtfe(indentStr));
		}
	}
	body
{
	return __ctfe ? s.indentCtfe(indentStr) : s.indentRuntime(indentStr);
}

@system unittest
{
	static assert(`<
		a b c
		d
			e
		f
			g
				h
	>`.indent() == `	<
			a b c
			d
				e
			f
				g
					h
		>`);
}


import std.stdio;
/***************************************************************************
 * 
 */
void truncate(ref File f, size_t fileSize = -1)
{
	ulong oldptr = -1;
	scope (exit)
	{
		if (oldptr != -1)
			f.seek(oldptr);
	}
	version (Windows)
	{
		import core.sys.windows.windows;
		if (fileSize != -1)
		{
			ulong p = f.tell;
			if (p != fileSize)
				oldptr = p;
			f.seek(fileSize);
		}
		SetEndOfFile(f.windowsHandle);
	}
	else version (Posix)
	{
		import core.sys.posix.unistd, core.sys.posix.sys.types;
		ftruncate(cast(int)f.getFP, cast(off_t)f.tell);
	}
}



/*******************************************************************************
 * 新しいパスを現在のパスの後ろに追加します
 */
void addPathAfter(string newpath)
{
	import std.process;
	if (auto path = environment.get("Path", null))
	{
		environment["Path"] = path ~ ";" ~ newpath;
		return;
	}
	if (auto path = environment.get("PATH", null))
	{
		environment["PATH"] = path ~ ";" ~ newpath;
		return;
	}
	if (auto path = environment.get("path", null))
	{
		environment["path"] = path ~ ";" ~ newpath;
		return;
	}
	environment["PATH"] = newpath;
}

/*******************************************************************************
 * 新しいパスを現在のパスの前に追加します
 */
void addPathBefore(string newpath)
{
	import std.process;
	if (auto path = environment.get("Path", null))
	{
		environment["Path"] = newpath ~ ";" ~ path;
		return;
	}
	if (auto path = environment.get("PATH", null))
	{
		environment["PATH"] = newpath ~ ";" ~ path;
		return;
	}
	if (auto path = environment.get("path", null))
	{
		environment["path"] = newpath ~ ";" ~ path;
		return;
	}
	environment["PATH"] = newpath;
}

/*******************************************************************************
 * MBS(ZeroNIL)文字列からUTF8に変換
 */
string fromMBS(in ubyte[] data, uint codePage = 0)
{
	version (Windows)
	{
		import std.windows.charset: fromMBSz;
		auto buf = data ~ 0;
		return fromMBSz(cast(immutable char*)buf.ptr, codePage);
	}
	else
	{
		// Windows以外では無視する。
		return cast(string)data.idup;
	}
}


/*******************************************************************************
 * UTF16(ZeroNIL)文字列からUTF8に変換
 */
string fromUTF16z(in wchar* data)
{
	import std.utf: toUTF8;
	const(wchar)* p = data;
	while (*p != '\0')
		++p;
	return toUTF8(data[0..(p - data)]);
}



/*******************************************************************************
 * UTF8からMBS(ZeroNIL)文字列に変換
 */
const(char)[] toMBS(in char[] data, uint codePage = 0)
{
	version (Windows)
	{
		import std.windows.charset: toMBSz;
		import core.stdc.string: strlen;
		auto dat = toMBSz(cast(string)data, codePage);
		return dat[0..strlen(dat)];
	}
	else
	{
		// Windows以外では無視する。
		return cast(string)data.idup;
	}
}


/*******************************************************************************
 * 
 */
enum MacroType
{
	/// $xxx, ${xxx}
	str,
	/// $(xxx)
	expr
}

/*******************************************************************************
 * Expands macro variables contained within a str
 */
T expandMacro(T, Func)(in T str, Func mapFunc)
	if (isSomeString!T
	&& isCallable!Func
	&& is(ReturnType!Func: bool)
	&& ParameterTypeTuple!Func.length >= 1
	&& is(T: ParameterTypeTuple!Func[0])
	&& (ParameterStorageClassTuple!Func[0] & ParameterStorageClass.ref_) == ParameterStorageClass.ref_)
{
	bool func(ref T arg, MacroType type, bool expandRecurse)
	{
		if (expandRecurse)
			arg = arg.expandMacroImpl!(T, func)();
		static if (ParameterTypeTuple!Func.length == 1)
		{
			return mapFunc(arg);
		}
		else
		{
			return mapFunc(arg, type);
		}
	}
	return str.expandMacroImpl!(T, func)();
}

/// ditto
T expandMacro(T, Func)(in T str, Func mapFunc)
	if (isSomeString!T
	&& isCallable!Func
	&& is(ReturnType!Func: T)
	&& ParameterTypeTuple!Func.length >= 1
	&& is(T: ParameterTypeTuple!Func[0]))
{
	bool func(ref T arg, MacroType type, bool expandRecurse)
	{
		if (expandRecurse)
			arg = arg.expandMacroImpl!(T, func)();
		static if (ParameterTypeTuple!Func.length == 1)
		{
			arg = mapFunc(arg);
		}
		else
		{
			arg = mapFunc(arg, type);
		}
		return true;
	}
	
	return str.expandMacroImpl!(T, func)();
}

/// ditto
T expandMacro(T, MAP)(in T str, MAP map)
	if (isSomeString!T
	&& is(typeof({ auto p = T.init in map; T tmp = *p; })))
{
	bool func(ref T arg, MacroType type, bool expandRecurse)
	{
		if (expandRecurse)
			arg = arg.expandMacroImpl!(T, func)();
		if (auto p = arg in map)
		{
			arg = *p;
			return true;
		}
		return false;
	}
	return str.expandMacroImpl!(T, func)();
}


private size_t searchEnd1(Ch)(const(Ch)[] str)
{
	size_t i = 0;
	import std.regex;
	if (auto m = str.match(ctRegex!(cast(Ch[])`^[a-zA-Z_].*?\b`)))
	{
		return m.hit.length;
	}
	return -1;
}

@system unittest
{
	assert(searchEnd1("abcde-fgh") == 5);
	assert(searchEnd1("abcde$fgh") == 5);
	assert(searchEnd1("abcde_fgh") == 9);
	assert(searchEnd1("abcde") == 5);
	assert(searchEnd1("$abcde") == -1);
	assert(searchEnd1("") == -1);
}

private size_t searchEnd2(Ch)(const(Ch)[] str, Ch ch)
{
	size_t i = 0;
	while (i < str.length)
	{
		if (str[i] == ch)
			return i;
		if (str[i] == '$')
		{
			if (i+1 < str.length)
			{
				// 連続する$$は無視
				if (str[i+1] == '$')
				{
					i+=2;
					continue;
				}
				if (str[i+1] == '(')
				{
					auto i2 = searchEnd2(str[i+2..$], ')');
					if (i2 == -1)
						return -1;
					i += i2 + 3;
				}
				else if (str[i+1] == '{')
				{
					auto i2 = searchEnd2(str[i+2..$], '}');
					if (i2 == -1)
						return -1;
					i += i2 + 3;
				}
				else
				{
					auto i2 = searchEnd1(str[i+1..$]);
					if (i2 == -1)
						return -1;
					i += i2 + 1;
				}
			}
			else
			{
				return -1;
			}
		}
		else
		{
			++i;
		}
	}
	return -1;
}
@system unittest
{
	assert(searchEnd2("abcde-f)gh", ')') == 7);
	assert(searchEnd2("abcde$f)gh", ')') == 7);
	assert(searchEnd2("abcde_f)gh", ')') == 7);
	assert(searchEnd2("abcde_fgh)", ')') == 9);
	assert(searchEnd2("abcde_$(f)gh)", ')') == 12);
	assert(searchEnd2("abcde_${f}gh)xx", ')') == 12);
}

private T expandMacroImpl(T, alias func)(in T str)
	if (isSomeString!T
	&& isCallable!func
	&& is(ReturnType!func: bool)
	&& ParameterTypeTuple!func.length == 3
	&& is(T:         ParameterTypeTuple!func[0])
	&& is(MacroType: ParameterTypeTuple!func[1])
	&& is(bool:      ParameterTypeTuple!func[2])
	&& (ParameterStorageClassTuple!func[0] & ParameterStorageClass.ref_) == ParameterStorageClass.ref_)
{
	import std.array, std.algorithm;
	Appender!T result;
	T rest = str[];
	size_t idxBegin, idxEnd;
	
	while (1)
	{
		idxBegin = rest.countUntil('$');
		if (idxBegin == -1 || idxBegin+1 >= rest.length)
			return result.data ~ rest;
		
		result ~= rest[0..idxBegin];
		
		if (rest[idxBegin+1] == '(')
		{
			auto head = rest[idxBegin..idxBegin+2];
			rest = rest[idxBegin+2..$];
			idxEnd = searchEnd2(rest, ')');
			if (idxEnd == -1)
				return result.data ~ head ~ rest;
			assert(rest[idxEnd] == ')');
			auto tmp = rest[0..idxEnd];
			if (func(tmp, MacroType.expr, true))
			{
				result ~= tmp;
				rest    = rest[idxEnd+1..$];
			}
			else
			{
				result ~= head ~ tmp ~ rest[idxEnd..idxEnd+1];
				rest    = rest[idxEnd+1..$];
			}
		}
		else if (rest[idxBegin+1] == '{')
		{
			auto head = rest[idxBegin..idxBegin+2];
			rest = rest[idxBegin+2..$];
			idxEnd = searchEnd2(rest, '}');
			if (idxEnd == -1)
				return result.data ~ head ~ rest;
			assert(rest[idxEnd] == '}');
			auto tmp = rest[0..idxEnd];
			if (func(tmp, MacroType.str, true))
			{
				result ~= tmp;
				rest    = rest[idxEnd+1..$];
			}
			else
			{
				result ~= head ~ tmp ~ rest[idxEnd..idxEnd+1];
				rest    = rest[idxEnd+1..$];
			}
		}
		else if (rest[idxBegin+1] == '$')
		{
			result ~= rest[idxBegin+1];
			rest = rest[idxBegin+2..$];
		}
		else
		{
			auto head = rest[idxBegin..idxBegin+1];
			rest = rest[idxBegin+1..$];
			idxEnd = searchEnd1(rest);
			if (idxEnd == -1)
				return result.data ~ rest;
			auto tmp = rest[0..idxEnd];
			if (func(tmp, MacroType.str, false))
			{
				result ~= tmp;
				rest    = rest[idxEnd..$];
			}
			else
			{
				result ~= head ~ tmp;
				rest    = rest[idxEnd..$];
			}
		}
	}
	assert(0);
}

@system unittest
{
	import std.meta;
	assert("x${$(aaa)x}${$(aaa)y}".expandMacro(["aaa": "AAA", "AAAx": "BBB"]) == "xBBB${AAAy}");
	static foreach (T; AliasSeq!(string, wstring, dstring))
	{{
		T str = "test$(xxx)${zzz}test$$${yyy}";
		T[T] map = ["xxx": "XXX", "yyy": "YYY"];
		assert(str.expandMacro(map) == "testXXX${zzz}test$YYY");
		assert(expandMacro(cast(T)"test$(yyy", map) == "test$(yyy");
		assert(expandMacro(cast(T)"test${zzz", map) == "test${zzz");
		
		auto foo = function T(T arg)
		{
			if (arg == cast(T)"xxx")
				return cast(T)"XXX";
			if (arg == cast(T)"abcXXX")
				return cast(T)"yyy";
			return cast(T)"ooo";
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", foo) == "xxxoooyyy");
		
		auto bar = delegate bool(ref T arg)
		{
			if (arg == cast(T)"xxx")
			{
				arg = cast(T)"XXX";
				return true;
			}	
			if (arg == cast(T)"abcXXX")
			{
				arg = cast(T)"yyy";
				return true;
			}
			return false;
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", bar) == "xxx$yyyyyy");
		assert(expandMacro(cast(T)"xxx$(aaa)", bar) == "xxx$(aaa)");
		assert(expandMacro(cast(T)"xxx$$(aaa)", bar) == "xxx$(aaa)");
		assert(expandMacro(cast(T)"xxx$(a$$aa)", bar) == "xxx$(a$aa)");
		assert(expandMacro(cast(T)"xxx$(a$(aa", bar) == "xxx$(a$(aa");
		assert(expandMacro(cast(T)"xxx$(a$...", bar) == "xxx$(a$...");
		assert(expandMacro(cast(T)"xxx$(a$", bar) == "xxx$(a$");
		
		auto foo2 = function T(T arg, MacroType ty)
		{
			if (arg == cast(T)"xxx")
				return ty == MacroType.str ? cast(T)"XXX1" : cast(T)"XXX2";
			if (arg == cast(T)"abcXXX1")
				return ty == MacroType.str ? cast(T)"yyy1" : cast(T)"yyy2";
			return ty == MacroType.str ? cast(T)"ooo1" : cast(T)"ooo2";
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", foo2) == "xxxooo1yyy2");
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx}", foo2) == "xxxooo1$(abc${xxx}");
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx", foo2) == "xxxooo1$(abc${xxx");
		assert(expandMacro(cast(T)"xxx$...", foo2) == "xxx...");
		
		auto bar2 = delegate bool(ref T arg, MacroType ty)
		{
			if (arg == cast(T)"xxx")
			{
				arg = ty == MacroType.str ? cast(T)"XXX1" : cast(T)"XXX2";
				return true;
			}	
			if (arg == cast(T)"abcXXX1")
			{
				arg = ty == MacroType.str ? cast(T)"yyy1" : cast(T)"yyy2";
				return true;
			}
			return false;
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", bar2) == "xxx$yyyyyy2");
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx}", bar2) == "xxx$yyy$(abc${xxx}");
	}}
}


/*******************************************************************************
 * 文字列内に含まれる変数を展開します。
 * 
 * `aaa%VAR%bbb`のVAR変数を展開します。変数が存在しない場合は何もしません。
 * VARがxxxであれば、`aaaxxxbbb`となります。
 * VARが存在しなければ、`aaa%VAR%bbb`のままです。
 */
T expandVariable(T, MAP)(in T str, MAP map)
	if (isSomeString!T
	&& is(typeof({ auto p = T.init in map; T var = *p; })))
{
	bool func(ref T arg)
	{
		if (auto p = arg in map)
		{
			arg = *p;
			return true;
		}
		return false;
	}
	return expandVariableImpl!(T, func)(str);
}
/// ditto
T expandVariable(T, Func)(in T str, Func mapFunc)
	if (isSomeString!T
	&& isCallable!Func
	&& is(ReturnType!Func: T)
	&& ParameterTypeTuple!Func.length == 1
	&& is(T: ParameterTypeTuple!Func[0]))
{
	bool func(in T arg)
	{
		arg = mapFunc(arg);
		return ture;
	}
	return expandVariableImpl!(T, func)(str);
}

private T expandVariableImpl(T, alias func)(in T str)
	if (isSomeString!T
	&& isCallable!func
	&& is(ReturnType!func: bool)
	&& ParameterTypeTuple!func.length == 1
	&& is(ParameterTypeTuple!func[0] == T)
	&& (ParameterStorageClassTuple!func[0] & ParameterStorageClass.ref_) == ParameterStorageClass.ref_)
{
	import std.array, std.algorithm;
	Appender!T result;
	T rest = str[];
	size_t idxBegin, idxEnd;
	while (1)
	{
		idxBegin = rest.countUntil('%');
		
		if (idxBegin == -1 || idxBegin+1 >= rest.length)
			return result.data ~ rest;
		
		idxEnd = rest[idxBegin+1..$].countUntil('%');
		if (idxEnd == -1)
			return result.data ~ rest;
		
		idxEnd += idxBegin+2;
		if (idxBegin+2 == idxEnd)
		{
			result ~= rest[0..idxBegin+1];
			rest    = rest[idxEnd..$];
		}
		else
		{
			auto tmp = rest[idxBegin+1 .. idxEnd-1];
			if (func(tmp))
			{
				result ~= rest[0..idxBegin] ~ tmp;
				rest    = rest[idxEnd..$];
			}
			else
			{
				result ~= rest[0..idxBegin+1] ~ tmp;
				rest    = rest[idxEnd-1..$];
			}
		}
	}
	assert(0);
}
@system unittest
{
	import std.meta;
	static foreach (T; AliasSeq!(string, wstring, dstring))
	{{
		T str = "test%xxx%te%%st%yyy%";
		T[T] map = ["xxx": "XXX"];
		assert(str.expandVariable(map) == "testXXXte%st%yyy%");
	}}
}

