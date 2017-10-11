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
	if (!is(typeof(fn!Args)) && isCallable!fn)
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
	if (is(typeof(fn!Args)) && isCallable!(fn!Args))
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



debug private void dispImpl(T...)(T args)
{
	import std.stdio, std.string;
	writeln(args);
}

debug void disp(T...)(T args) nothrow pure @nogc @trusted
{
	assumeAttr!(dispImpl!T, FunctionAttribute.nothrow_ | FunctionAttribute.pure_ | FunctionAttribute.nogc)(args);
}

private template AssumedUnsharedType(T)
{
	import std.traits;
	static if (is(T U == shared(U)))
	{
		alias AssumedUnsharedType!(U) AssumedUnsharedType;
	}
	else static if (is(T U == const(shared(U))))
	{
		alias const(AssumedUnsharedType!(U)) AssumedUnsharedType;
	}
	else static if (isPointer!T)
	{
		alias AssumedUnsharedType!(pointerTarget!T)* AssumedUnsharedType;
	}
	else static if (isDynamicArray!T)
	{
		alias AssumedUnsharedType!(ForeachType!T)[] AssumedUnsharedType;
	}
	else static if (isStaticArray!T)
	{
		alias AssumedUnsharedType!(ForeachType!T)[T.length] AssumedUnsharedType;
	}
	else static if (isAssociativeArray!T)
	{
		alias AssumedUnsharedType!(ValueType!T)[AssumedUnsharedType!(KeyType!T)] AssumedUnsharedType;
	}
	else
	{
		alias T AssumedUnsharedType;
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


unittest
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
		alias ParameterTypeTuple!(t1) a1;
		alias ReturnType!(t1) r1;
		
		static if (i < T.length-1)
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
			alias ParameterTypeTuple!(t2) a2;
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
		alias ParameterTypeTuple!fn Args;
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

version(none) unittest
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

unittest
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

