/*******************************************************************************
 * 
 */
module voile.misc;

import core.memory, core.thread, core.exception;
import std.concurrency, std.parallelism;
import std.stdio, std.exception, std.conv, std.string, std.variant;
import std.range, std.container, std.array;
import std.functional, std.typecons, std.traits, std.typetuple, std.metastrings;


/* This template based from std.typecons.MemberFunctionGenerator */
private template MemberFunctionGeneratorEx(alias Policy)
{
private static:
	//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
	// Internal stuffs
	//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

	enum CONSTRUCTOR_NAME = "__ctor";

	// true if functions are derived from a base class
	enum WITH_BASE_CLASS = __traits(hasMember, Policy, "BASE_CLASS_ID");

	// true if functions are specified as types, not symbols
	enum WITHOUT_SYMBOL = __traits(hasMember, Policy, "WITHOUT_SYMBOL");

	// preferred identifier for i-th parameter variable
	static if (__traits(hasMember, Policy, "PARAMETER_VARIABLE_ID"))
	{
		alias Policy.PARAMETER_VARIABLE_ID PARAMETER_VARIABLE_ID;
	}
	else
	{
		template PARAMETER_VARIABLE_ID(size_t i)
		{
			enum string PARAMETER_VARIABLE_ID = "a" ~ toStringNow!(i);
				// default: a0, a1, ...
		}
	}

	// Returns a tuple consisting of 0,1,2,...,n-1.  For static foreach.
	template CountUp(size_t n)
	{
		static if (n > 0)
			alias TypeTuple!(CountUp!(n - 1), n - 1) CountUp;
		else
			alias TypeTuple!() CountUp;
	}


	//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
	// Code generator
	//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

	/*
	 * Runs through all the target overload sets and generates D code which
	 * implements all the functions in the overload sets.
	 */
	public string generateCode(overloads...)() @property
	{
		string code = "";

		// run through all the overload sets
		foreach (i_; CountUp!(0 + overloads.length)) // workaround
		{
			enum i = 0 + i_; // workaround
			alias overloads[i] oset;

			code ~= generateCodeForOverloadSet!(oset);

			static if (WITH_BASE_CLASS && oset.name != CONSTRUCTOR_NAME)
			{
				// The generated function declarations may hide existing ones
				// in the base class (cf. HiddenFuncError), so we put an alias
				// declaration here to reveal possible hidden functions.
				code ~= Format!("alias %s.%s %s;\n",
							Policy.BASE_CLASS_ID, // [BUG 2540] super.
							oset.name, oset.name );
			}
		}
		return code;
	}

	// handle each overload set
	private string generateCodeForOverloadSet(alias oset)() @property
	{
		string code = "";

		foreach (i_; CountUp!(0 + oset.contents.length)) // workaround
		{
			enum i = 0 + i_; // workaround
			code ~= generateFunction!(
					Policy.FUNCINFO_ID!(oset.name, i), oset.name,
					oset.contents[i]) ~ "\n";
		}
		return code;
	}

	/*
	 * Returns D code which implements the function func.  This function
	 * actually generates only the declarator part; the function body part is
	 * generated by the functionGenerator() policy.
	 */
	public string generateFunction(
			string myFuncInfo, alias exFuncInfo, string name, func...)() @property
	{
		enum isCtor = (name == CONSTRUCTOR_NAME);

		string code; // the result

		/*** Function Declarator ***/
		{
			alias exFuncInfo.FuncType Func;
			alias FunctionAttribute FA;
			enum atts     = exFuncInfo.attrib;
			enum realName = isCtor ? "this" : name;

			/* Made them CTFE funcs just for the sake of Format!(...) */

			// return type with optional "ref"
			static string make_returnType()
			{
				string rtype = "";

				if (!isCtor)
				{
					if (atts & FA.ref_) rtype ~= "ref ";
					rtype ~= myFuncInfo ~ ".RT";
				}
				return rtype;
			}
			enum returnType = make_returnType();

			// function attributes attached after declaration
			static string make_postAtts()
			{
				string poatts = "";
				if (atts & FA.pure_   ) poatts ~= " pure";
				if (atts & FA.nothrow_) poatts ~= " nothrow";
				if (atts & FA.property) poatts ~= " @property";
				if (atts & FA.safe    ) poatts ~= " @safe";
				if (atts & FA.trusted ) poatts ~= " @trusted";
				return poatts;
			}
			enum postAtts = make_postAtts();

			// function storage class
			static string make_storageClass()
			{
				string postc = "";
				if (is(Func ==    shared)) postc ~= " shared";
				if (is(Func ==     const)) postc ~= " const";
				if (is(Func == immutable)) postc ~= " immutable";
				return postc;
			}
			enum storageClass = make_storageClass();

			//
			if (exFuncInfo.abst)
				code ~= "override ";
			code ~= Format!("extern(%s) %s %s(%s) %s %s\n",
					exFuncInfo.linkage,
					returnType,
					realName,
					""~generateParameters!(myFuncInfo, exFuncInfo),
					postAtts, storageClass );
		}

		/*** Function Body ***/
		code ~= "{\n";
		{
			enum nparams = exFuncInfo.PT.length;

			/* Declare keywords: args, self and parent. */
			string preamble;

			preamble ~= "alias TypeTuple!(" ~ enumerateParameters!(nparams) ~ ") args;\n";
			if (!isCtor)
			{
				preamble ~= "alias " ~ name ~ " self;\n";
				if (WITH_BASE_CLASS && !exFuncInfo.abst)
					//preamble ~= "alias super." ~ name ~ " parent;\n"; // [BUG 2540]
					preamble ~= "auto parent = &super." ~ name ~ ";\n";
			}

			// Function body
			static if (WITHOUT_SYMBOL)
				enum fbody = Policy.generateFunctionBody!(name, func);
			else
				enum fbody = Policy.generateFunctionBody!(func);

			code ~= preamble;
			code ~= fbody;
		}
		code ~= "}";

		return code;
	}

	/*
	 * Returns D code which declares function parameters.
	 * "ref int a0, real a1, ..."
	 */
	private string generateParameters(string myFuncInfo, alias exFuncInfo)() @property
	{
		alias ParameterStorageClass STC;
		alias exFuncInfo.stcs stcs;
		alias exFuncInfo.valiadic valiadic;
		enum nparams = stcs.length;

		string params = ""; // the result

		foreach (i, stc; stcs)
		{
			if (i > 0) params ~= ", ";

			// Parameter storage classes.
			if (stc & STC.scope_) params ~= "scope ";
			if (stc & STC.out_  ) params ~= "out ";
			if (stc & STC.ref_  ) params ~= "ref ";
			if (stc & STC.lazy_ ) params ~= "lazy ";

			// Take parameter type from the FuncInfo.
			params ~= myFuncInfo ~ ".PT[" ~ toStringNow!(i) ~ "]";

			// Declare a parameter variable.
			params ~= " " ~ PARAMETER_VARIABLE_ID!(i);
		}

		// Add some ellipsis part if needed.
		final switch (valiadic)
		{
			case Variadic.no:
				break;

			case Variadic.c, Variadic.d:
				// (...) or (a, b, ...)
				params ~= (nparams == 0) ? "..." : ", ...";
				break;

			case Variadic.typesafe:
				params ~= " ...";
				break;
		}

		return params;
	}

	// Returns D code which enumerates n parameter variables using comma as the
	// separator.  "a0, a1, a2, a3"
	private string enumerateParameters(size_t n)() @property
	{
		string params = "";

		foreach (i_; CountUp!(n))
		{
			enum i = 0 + i_; // workaround
			if (i > 0) params ~= ", ";
			params ~= PARAMETER_VARIABLE_ID!(i);
		}
		return params;
	}
}
/* This template based from std.functional.DelegateFaker */
private struct DelegateFakerEx(F) {
	template GeneratingPolicy()
	{
		enum WITHOUT_SYMBOL = true;
		template generateFunctionBody(unused...)
		{
			enum generateFunctionBody =
			q{
				auto fp = cast(F) &this;
				return fp(null, args);
			};
		}
	}
	template FuncInfo(Func)
	{
		alias         ReturnType!(Func)       RT;
		alias ParameterTypeTuple!(Func)[1..$] PT;
	}
	alias FuncInfo!(F) FuncInfo_doIt;
	template ExFuncInfo()
	{
		alias FunctionTypeOf!(F)                   FuncType;
		alias ReturnType!(F)                       RT;
		alias ParameterTypeTuple!(F)[1..$]         PT;
		alias ParameterStorageClassTuple!(F)[1..$] stcs;
		alias variadicFunctionStyle!(F)            valiadic;
		alias functionAttributes!(F)               attrib;
		alias functionLinkage!(F)                  linkage;
		alias isAbstractFunction!(F)               abst;
	}
	mixin( MemberFunctionGeneratorEx!(GeneratingPolicy!())
			.generateFunction!("FuncInfo_doIt", ExFuncInfo!(), "doIt") );
}

// easter egg
auto toDelegateEx(Ptr, F)(Ptr ptr, F funcptr)
	if (Ptr.sizeof == size_t.sizeof && isCallable!F &&
	    is(Ptr: ParameterTypeTuple!(F)[0]))
{
	alias typeof(&(new DelegateFakerEx!(F)).doIt) DelType;
	static struct _ConnectData
	{
		union
		{
			struct
			{
				void* ptr;
				void* funcptr;
			}
			DelType dg;
		}
	}
	return _ConnectData(cast(void*)ptr, cast(void*)funcptr).dg;
}

unittest
{
	int[] testary;
	class Foo
	{
		int bar;
		void foo()
		{
			testary ~= bar;
		}
	}
	void delegate()[] dgs;
	static void func(Foo foo)
	{
		foo.foo();
	}
	foreach (i; 0..10)
	{
		auto f = new Foo;
		f.bar = i;
		dgs ~= toDelegateEx(f, &func);
	}
	foreach (dg; dgs)
	{
		dg();
	}
	assert(testary == [0,1,2,3,4,5,6,7,8,9]);
	
	
	testary =  null;
	
	extern(C) void delegate()[] dgs2;
	static extern(C) void func2(Foo foo)
	{
		foo.foo();
	}
	foreach (i; 0..10)
	{
		auto f = new Foo;
		f.bar = i;
		dgs2 ~= toDelegateEx(f, &func2);
	}
	foreach (dg; dgs2)
	{
		dg();
	}
	assert(testary == [0,1,2,3,4,5,6,7,8,9]);
}


/*******************************************************************************
 * List container
 */
class List(T)
{
private:
	struct Node
	{
		T     val;
		Node* next;
		Node* prev;
		this(T v, Node* n, Node* p) pure nothrow
		{
			val = v;
			next = n;
			prev = p;
		}
	}
	Node* root;
public:
	/***************************************************************************
	 * 
	 */
	struct Iterator
	{
	private:
		List  list;
		Node* node;
		this(List l, Node* n) pure nothrow
		{
			list = l;
			node = n;
		}
	public:
		/***********************************************************************
		 * Iterator primitives.
		 */
		ref T opStar()
		{
			enforce(node !is list.root);
			return node.val;
		}
		
		/// ditto
		R opCast(R)() const nothrow pure
			if (is(R==bool))
		{
			return list !is null && node !is list.root;
		}
		
		/// ditto
		ref Iterator opUnary(string op)()
			if (op == "++")
		{
			enforce(node !is list.root);
			node = node.next;
			return this;
		}
		
		/// ditto
		ref Iterator opUnary(string op)()
			if (op == "--")
		{
			enforce(node.prev !is list.root);
			node = node.prev;
			return this;
		}
		
		/// ditto
		ref Iterator opOpAssign(string op)(size_t i)
			if (op == "+")
		{
			foreach (Unused; 0..i)
			{
				++this;
			}
			return this;
		}
		
		/// ditto
		ref Iterator opOpAssign(string op)(size_t i)
			if (op == "-")
		{
			foreach (Unused; 0..i)
			{
				--this;
			}
			return this;
		}
		
		/// ditto
		bool opEquals(Iterator itr) const pure nothrow
		{
			return itr.node is node;
		}
		
		/// ditto
		int opCmp(Iterator itr) const pure
		{
			enforce(list is itr.list);
			if (node is itr.node) return 0;
			const(Node)* l = node;
			const(Node)* r = itr.node;
			while (1)
			{
				l = l.next;
				r = r.next;
				if (l is itr.node)
					return 1;
				if (l is list.root)
					return 1;
				if (r is list.root)
					return -1;
				if (r is node)
					return -1;
			}
			assert(0);
		}
		
		
		/// ditto
		ref Iterator opBinary(string op)(Iterator itr)
			if (op == "-")
		{
			enforce(list is itr.list);
			size_t i;
			for (auto n = node; ; n = n.next)
			{
				if (n is itr.node) return i;
				n = n.next;
				enforce(n !is list.root);
				++i;
			}
			enforce(0);
		}
		
	}
	
	/***************************************************************************
	 * 
	 */
	struct Range
	{
	private:
		List  _list;
		Node* _first;
		Node* _end;
		this(List l, Node* f, Node* e) pure nothrow
		{
			_list  = l;
			_first = f;
			_end   = e;
		}
	public:
		/***********************************************************************
		 * Range primitives.
		 */
		@property bool empty() const
		{
			return _first is _end;
		}
		
		/// ditto
		@property T front()
		{
			enforce(!empty);
			return _first.val;
		}
		
		/***********************************************************************
		 * 
		 */
		@property T back()
		{
			enforce(!empty);
			return _end.prev.val;
		}
		
		/// ditto
		void popFront()
		{
			enforce(!empty);
			assert(_first is _first.next.prev);
			assert(_first is _first.prev.next);
			assert(_end is _end.next.prev);
			assert(_end is _end.prev.next);
			_first = _first.next;
		}
		
		/// ditto
		void popBack()
		{
			enforce(!empty);
			assert(_first is _first.next.prev);
			assert(_first is _first.prev.next);
			assert(_end is _end.next.prev);
			assert(_end is _end.prev.next);
			_end = _end.prev;
		}
		
		/// ditto
		@property Range save()
		{
			return this;
		}
		
		/***********************************************************************
		 * Iterator accessor
		 */
		@property Iterator begin()
		{
			return Iterator(_list, _first);
		}
		
		/// ditto
		@property Iterator end()
		{
			return Iterator(_list, _end);
		}
	}
	
	this()
	{
		static if (__traits(compiles, { T v; }))
		{
			T v;
		}
		else static if (__traits(compiles, { T v = T.init; }))
		{
			T v = T.init;
		}
		else
		{
			T v = void;
		}
		root = new Node(v, null, null);
		root.next = root;
		root.prev = root;
	}
	
	@property bool empty() const pure nothrow
	{
		return root.next is root;
	}
	
	@property T front() pure
	{
		enforce(root.next !is root);
		return root.next.val;
	}
	
	@property T back() pure
	{
		enforce(root.prev !is root);
		return root.prev.val;
	}
	
	
	/***************************************************************************
	 * Range accessor
	 */
	Range opSlice() pure nothrow
	{
		return Range(this, root.next, root);
	}
	
	/***************************************************************************
	 * Iterator accessor
	 */
	@property Iterator begin() pure nothrow
	{
		return Iterator(this, root.next);
	}
	
	/// ditto
	@property Iterator end() pure nothrow
	{
		return Iterator(this, root);
	}
	
	/***************************************************************************
	 * Container premitive
	 */
	void stableInsertFront(T val) pure nothrow
	{
		auto node = new Node(val, root.next, root);
		root.next.prev = node;
		root.next = node;
	}
	/// ditto
	alias stableInsertFront insertFront;
	
	/// ditto
	void stableInsertBack(T val) pure nothrow
	{
		auto node = new Node(val, root, root.prev);
		root.prev.next = node;
		root.prev = node;
	}
	/// ditto
	alias stableInsertBack insertBack;
	/// ditto
	alias insertBack insert;
	
	
	/// ditto
	void stableInsertBefore(Iterator itr, T val)
	{
		enforce(this is itr.list);
		auto head = itr.node;
		auto node = new Node(val, head, head.prev);
		head.prev.next = node;
		head.prev = node;
	}
	
	/// ditto
	void stableInsertBefore(Range r, T val)
	{
		stableInsertBefore(r.begin, val);
	}
	
	/// ditto
	alias stableInsertBefore insertBefore;
	
	/// ditto
	void stableInsertAfter(Iterator itr, T val)
	{
		auto tail = itr.node;
		auto node = new Node(val, tail.next, tail);
		tail.next.prev = node;
		tail.next = node;
	}
	/// ditto
	void stableInsertAfter(Range r, T val)
	{
		stableInsertAfter(--r.end, val);
	}
	/// ditto
	alias stableInsertAfter insertAfter;
	
	/// ditto
	void stableLinearRemove(Range r)
	{
		auto n1 = r._first.prev;
		auto n2 = r._end;
		n1.next = n2;
		n2.prev = n1;
	}
	
	/// ditto
	void stableLinearRemove(Iterator itr)
	{
		auto n1 = itr.node.prev;
		auto n2 = itr.node.next;
		n1.next = n2;
		n2.prev = n1;
	}
	
	private static Range convert(Take!Range r)
	{
		auto first = r.source._first;
		auto end = first;
		foreach (i; 0..r.maxLength)
		{
			assert(end);
			assert(end.next);
			end = end.next;
		}
		return Range(r.source._list, first, end);
	}
	
	/// ditto
	void stableLinearRemove(Take!Range r)
	{
		stableLinearRemove(convert(r));
	}
	
	/// ditto
	void clear()
	{
		root.next = root;
		root.prev = root;
	}
}

unittest
{
	auto list = new List!int;
	list.insertBack(1);
	assert(list.root.next.val == 1);
	assert(list.root.prev.val == 1);
	list.insertBack(2);
	assert(list.root.next.val == 1);
	assert(list.root.next.next.val == 2);
	assert(list.root.prev.val == 2);
	assert(list.root.prev.prev.val == 1);
	list.insertBack(3);
	assert(list.root.next.val == 1);
	assert(list.root.next.next.val == 2);
	assert(list.root.next.next.next.val == 3);
	assert(list.root.prev.val == 3);
	assert(list.root.prev.prev.val == 2);
	assert(list.root.prev.prev.prev.val == 1);
	list.insertFront(0);
	assert(list.root.next.val == 0);
	assert(list.root.prev.val == 3);
	list.insertAfter(list[], 4);
	list.insertBefore(list[], -1);
	auto r = list[];
	assert(r.begin < r.end);
	
	r.popFront();
	popFrontN(r, walkLength(r)-2);
	list.stableLinearRemove(take(r, 1));
	assert(walkLength(list[]) == 5);
	int[] ary;
	foreach (e; list[])
	{
		ary ~= e;
	}
	assert(ary == [-1,0,1,2,4]);
}




/*******************************************************************************
 * Generic Handler
 */
struct Handler(F)
	if (isCallable!F && is(ReturnType!(F) == void))
{
private:
	template _ExFuncInfo(Func)
	{
		alias FunctionTypeOf!(Func)             FuncType;
		alias ReturnType!(Func)                 RT;
		alias ParameterTypeTuple!(Func)         PT;
		alias ParameterStorageClassTuple!(Func) stcs;
		alias variadicFunctionStyle!(Func)      valiadic;
		alias functionAttributes!(Func)         attrib;
		alias functionLinkage!(Func)            linkage;
		alias isAbstractFunction!(Func)         abst;
	}
	alias _ExFuncInfo!(F) _exFuncInfo;
	template _EmitGeneratingPolicy()
	{
		template generateFunctionBody(unused...)
		{
			enum generateFunctionBody =
			q{
				if (!_procs) return;
				static if (_exFuncInfo.attrib & FunctionAttribute.nothrow_)
				{
					try
					{
						foreach (proc; _procs[])
						{
							proc(args);
						}
					}
					catch (Throwable)
					{
						
					}
				}
				else
				{
					foreach (proc; _procs[])
					{
						proc(args);
					}
				}
			};
		}
	}
public:
	/***************************************************************************
	 * 
	 */
	version (D_Ddoc) void emit(Args args);
	mixin( MemberFunctionGeneratorEx!(_EmitGeneratingPolicy!())
			.generateFunction!("_exFuncInfo", _exFuncInfo, "emit")() );
	/// ditto
	alias emit opCall;
private:
	alias typeof(&typeof(this).init.emit) Proc;
	alias _exFuncInfo.PT Args;
	alias List!Proc ProcList;
	ProcList.Range end;
	ProcList _procs;
public:
	/***************************************************************************
	 * 
	 */
	alias ProcList.Iterator HandlerProcId;
	
	/***************************************************************************
	 * Connect
	 * 
	 * Params:
	 *     fn = delegate, function, Tid, Object( has opCall ), Fiber
	 */
	HandlerProcId connect(Func)(Func fn)
		if (is(typeof( toDelegate(fn) )))
	{
		if (!_procs) _procs = new ProcList;
		_procs.stableInsertBack( toDelegate(fn) );
		return _procs.begin;
	}
	/// ditto
	void opOpAssign(string op)(F dg) if (op == "~" && is(typeof(connect(dg))))
	{
		connect(dg);
	}
	
	/***************************************************************************
	 * 
	 */
	HandlerProcId connectedId(Func)(Func fn)
		if (is(typeof( toDelegate(fn) )))
	{
		if (!_procs) return HandlerProcId.init;
		auto f = toDelegate(fn);
		for (auto r = _procs[]; !r.empty; r.popBack())
		{
			if (r.back == f)
			{
				return --r.end;
			}
		}
		
		return HandlerProcId.init;
	}
	
	HandlerProcId connect(Func)(Func tid)
		if (is(Func == Tid))
	{
		return connect(&(tid.send!(Args)));
	}
	
	HandlerProcId connectedId(Func)(Func tid)
		if (is(Func == Tid))
	{
		return connected(&(tid.send!(Args)));
	}
	
	static if (Args.length == 0)
	{
		static void _FiberCaller(Fiber fb)
		{
			fb.call();
		}
		HandlerProcId connect(Func)(Func fib)
			if (is(Func: Fiber))
		{
			return connect(toDelegateEx(fib, &_FiberCaller));
		}
		HandlerProcId connectedId(Func)(Func fib)
			if (is(Func: Fiber))
		{
			return connectedId(toDelegateEx(fib, &_FiberCaller));
		}
	}
	
	/***************************************************************************
	 * 
	 */
	void disconnect(Func)(Func fn)
		if (is(typeof( connectedId(fn) )))
	{
		disconnect(connectedId(fn));
	}
	
	/// ditto
	void disconnect(Func)(Func id)
		if (is(Func == HandlerProcId))
	{
		enforce(id);
		enforce(_procs);
		_procs.stableLinearRemove(id);
	}
	
	
	/***************************************************************************
	 * 
	 */
	void clear()
	{
		if (!_procs) return;
		_procs.clear();
	}
	
	
}


unittest
{
	static string teststr;
	static void foo(int i)
	{
		teststr ~= "foo" ~ to!string(i);
	}
	Handler!(typeof(foo)) h;
	auto id1 = h.connect( &foo );
	h.connect( (int i){teststr ~= "dg" ~ to!string(i);} );
	auto id2 = h.connect( new class
	{
		void opCall(int i)
		{
			teststr ~= "opCall" ~ to!string(i);
		}
	} );
	teststr = "";
	h(1);
	assert(teststr == "foo1dg1opCall1", teststr);
	h.disconnect( &foo );
	teststr = "";
	h(2);
	assert(teststr == "dg2opCall2", teststr);
	assert(!h.connectedId( &foo ));
	
	h.disconnect(id2);
	h.connect(thisTid);
	h.clear();
	
	
	void bar()
	{
		teststr ~= "bar";
	}
	Handler!(typeof(bar)) h2;
	Fiber fib = new Fiber(&bar);
	h2.connect(fib);
	teststr = "";
	h2();
	assert(teststr == "bar");
}

import std.stdio, std.algorithm, std.traits;
import core.memory;
import core.stdc.stdlib: malloc, free;


// Used by scoped() above
private extern (C) static void _d_monitordelete(Object h, bool det);

/*
  Used by scoped() above.  Calls the destructors of an object
  transitively up the inheritance path, but work properly only if the
  static type of the object (T) is known.
 */
private void destroy(T)(T obj)
{
	static if (is(T == class) || is(T == interface))
	{
		clear(obj);
	}
	else
	{
		static if (is(typeof(obj.__dtor())))
		{
			obj.__dtor();
		}
	}
}


/*******************************************************************************
 * 
 */
struct Unique(T)
{
private:
	static if ((is(T==class)||is(T==interface)))
	{
		alias std.traits.Unqual!T RefT;
	}
	else
	{
		alias std.traits.Unqual!T InstT;
		alias InstT* RefT;
	}
	
	
	RefT _p;
	
	enum Dummy { init }
	/***************************************************************************
	 * Constructor
	 */
	this(RefT p, Dummy dummy)
	{
		debug (Unique) writefln("%d: Unique constructor [%08x]", __LINE__, cast(void*)&this, cast(void*)_p);
		_p = p;
	}
	
	/***************************************************************************
	 * Constructor that takes an rvalue.
	 * It will ensure uniqueness, as long as the rvalue
	 * isn't just a view on an lvalue (e.g., a cast)
	 * Typical usage:
	 *----
	 *Unique!(Foo) f = new Foo;
	 *----
	 */
	this(RefT p, size_t sz)
	{
		debug (Unique) writefln("%d: Unique [%08x] constructor with rvalue [%08x]", __LINE__, cast(void*)&this, cast(void*)p);
		attach(p, sz);
		assert(_p);
	}
	
	/***************************************************************************
	 * 
	 */
	void attach(RefT p, size_t sz)
		in
		{
			assert(_p is null);
		}
	body
	{
		debug (Unique) writefln("%d: Unique Attach [%08x]", __LINE__,  cast(void*)p);
		_p = p;
		core.memory.GC.addRange(cast(void*)_p, sz);
	}
	
	
	/***************************************************************************
	 * 
	 */
	RefT detach()
		in
		{
			assert(_p !is null);
		}
	body
	{
		debug (Unique) writefln("%d: Unique Detach [%08x]", __LINE__, cast(void*)_p);
		scope (exit)
		{
			core.memory.GC.removeRange(cast(void*)_p);
			_p = null;
		}
		return _p;
	}
	
public:
	
	
	/** Forwards member access to contents */
	static if ((is(T==class)||is(T==interface)))
	{
		static if (is(T == const) && !is(T==shared))
		{
			@property @trusted nothrow pure
			T instance() const { return cast(T)_p; }
		}
		else static if (!is(T == const) && is(T==shared))
		{
			@property @trusted nothrow pure
			T instance() shared { return cast(T)_p; }
		}
		else static if (is(T == const) && is(T==shared))
		{
			@property @trusted nothrow pure
			T instance() const shared { return cast(T)_p; }
		}
		else
		{
			@property nothrow pure
			T instance() { return _p; }
		}
	}
	else
	{
		static if (is(T == const) && !is(T==shared))
		{
			@property @trusted nothrow pure
			ref T instance() const { return *cast(T*)_p; }
		}
		else static if (!is(T == const) && is(T==shared))
		{
			@property @trusted nothrow pure
			ref T instance() shared { return *cast(T*)_p; }
		}
		else static if (is(T == const) && is(T==shared))
		{
			@property @trusted nothrow pure
			ref T instance() const shared { return *cast(T*)_p; }
		}
		else
		{
			@property @safe nothrow pure
			ref T instance() { return *_p; }
		}
	}
	
	
	
	
	/***************************************************************************
	 * Postblit operator is undefined to prevent the cloning of $(D Unique)
	 * objects
	 */
	@disable this(this);
	
	
	~this()
	{
		debug (Unique) writefln("%d: Unique [%08x] destructor [%08x]", __LINE__, cast(void*)&this, cast(void*)_p);
		release();
	}
	
	
	/***************************************************************************
	 * Nullifies the current contents.
	 */
	@property @safe
	bool isEmpty() const
	{
		return _p is null;
	}
	
	
	/***************************************************************************
	 * 
	 */
	@trusted
	void release()
	{
		if (!_p) return;
		debug (Unique) writefln("%d: Unique [%08x] release of [%08x]", __LINE__, cast(void*)&this, cast(void*)_p);
		auto p = detach();
		assert(_p is null);
		static if (is(T==interface))
		{
			if (auto o = cast(Object)p)
			{
				destroy(o);
				if ((cast(void**)(cast(void*)o))[1]) // if monitor is not null
				{
					_d_monitordelete(o, true);
				}
			}
		}
		else
		{
			destroy(p);
		}
		free(cast(void*)p);
	}
	
	/***************************************************************************
	 * Returns a unique rvalue. Nullifies the current contents
	 */
	@trusted @property
	Unique!(R) move(R = T)()
		if (is(T: R))
	{
		debug (Unique) writefln("%d: Unique move [%08x]", __LINE__, cast(void*)_p);
		auto tmp = _p;
		_p = null;
		debug (Unique) writefln("%d: Unique return from move [%08x]", __LINE__, cast(void*)tmp);
		return Unique!R(cast(Unique!(R).RefT)tmp, Unique!(R).Dummy.init);
	}
	
	/***************************************************************************
	 * 
	 */
	@safe
	void swap(ref Unique u)
	{
		auto tmp = _p;
		_p = u._p;
		u._p = tmp;
	}
	
	
	
	//
	ref Unique!T opAssign(Unique!T u)
		in
		{
			assert(_p is null);
		}
		body
	{
		_p = u._p;
		u._p = null;
		return this;
	}
	
	
	
	// todo to PrxyOf
	alias instance this;
}



/*******************************************************************************
 * 
 */
@trusted @property
Unique!T unique(T)()
{
	return uniqueImpl!(T)();
}
/// ditto
@trusted
Unique!T unique(T, Args...)(Args args)
{
	return uniqueImpl!(T)(args);
}

Unique!T uniqueImpl(T, Args...)(Args args)
	if (is(Unique!T))
{
	alias Unique!(T).RefT RefT;
	static if (is(T == class))
	{
		enum instSize = __traits(classInstanceSize, T);
		auto payload = malloc(instSize)[0..instSize];
		payload[] = typeid(T).init[];
	}
	else static if (is(T==struct))
	{
		enum instSize = T.sizeof;
		auto payload = malloc(instSize)[0..instSize];
		*(cast(Unqual!(T)*)payload.ptr) = T.init;
	}
	static if (Args.length == 0)
	{
		static if (is(typeof(T.init.__ctor())))
		{
			(cast(RefT)payload.ptr).__ctor();
		}
	}
	else
	{
		emplace!T(cast(void[])payload, args);
	}
	
	return Unique!T(cast(RefT)payload.ptr, instSize);
}


unittest
{
	static int[] testary;
	{
		static struct Foo
		{
			~this() { testary ~= -1; }
			@property int val() const { return 3; }
		}
		alias Unique!(Foo) UFoo;
	
		UFoo f(UFoo u)
		{
			testary ~= -2;
			return move(u);
		}
		
		testary ~= 1;
		auto uf = unique!Foo;
		testary ~= 2;
		assert(!uf.isEmpty);
		assert(uf.val() == 3);
		// should not compile
		static assert(!__traits(compiles,
		{
			auto uf3 = f(uf);
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			uf = uf;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			auto uf2 = uf;
		}));
		auto uf2 = f(move(uf));
		testary ~= 3;
		assert(uf.isEmpty);
		assert(!uf2.isEmpty);
	}
	testary ~= 4;
	assert(testary == [1,2,-2,3,-1,4]);
}

unittest
{
	static int[] testary;
	{
		static class Bar
		{
			~this() { testary ~= -1; }
			@property int val() const { return 4; }
		}
		alias Unique!(Bar) UBar;
		UBar g(UBar u)
		{
			testary ~= -2;
			return move(u);
		}
		testary ~= 1;
		auto ub = unique!Bar;
		testary ~= 2;
		assert(!ub.isEmpty);
		assert(ub.val == 4);
		// should not compile
		static assert(!__traits(compiles,
		{
			auto ub3 = g(ub);
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			ub = ub;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			auto ub2 = ub;
		}));
		auto ub2 = g(move(ub));
		testary ~= 3;
		assert(ub.isEmpty);
		assert(!ub2.isEmpty);
	}
	testary ~= 4;
	assert(testary == [1,2,-2,3,-1,4]);
}

unittest
{
	static int[] testary;
	{
		static class A
		{
			~this() { testary ~= -1; }
			@property int val() const { return 4; }
		}
		static class B: A
		{
			~this() { testary ~= -2; }
			@property override int val() const { return 5; }
		}
		testary ~= 1;
		auto b = unique!B;
		testary ~= 2;
		auto a = b.move!A;
		testary ~= 3;
		assert(b.isEmpty);
		assert(!a.isEmpty);
		assert(a.val == 5);
		Unique!A a2;
		testary ~= 4;
		a2 = unique!A;
		testary ~= 5;
		static assert(!__traits(compiles,
		{
	//@@@TODO@@@
	//		A a3 = a2;
			A a3 = x;
		}));
	}
	testary ~= 6;
	assert(testary == [1,2,3,4,5,-1,-2,-1,6]);
}


unittest
{
	static int[] testary;
	{
		class A
		{
			this() { testary ~= -1; }
			~this() { testary ~= -2; }
			@property int val() const { return 4; }
		}
		class Foo
		{
			Unique!A a;
			this()
			{
				testary ~= -3;
				a = unique!A;
			}
			~this()
			{
				testary ~= -4;
				a.release();
			}
		}
		testary ~= 1;
		auto f = unique!Foo;
		testary ~= 2;
		assert(f.a.val == 4);
	}
	testary ~= 3;
	assert(testary == [1,-3,-1,2,-4,-2,3]);
}



/*******************************************************************************
 * 
 */
CommonType!(staticMap!(ReturnType, T))
	variantSwitch(T...)(Variant var, T caseFunctions)
{
	static assert(allSatisfy!(isCallable, T),
		"variantSwitch ascepts only callable");
	foreach (i, t1; T)
	{
		alias ParameterTypeTuple!(t1) a1;
		alias ReturnType!(t1) r1;
		
		static assert( a1.length != 1 || !is( a1[0] == Variant ),
			"case function with argument types " ~ a1.stringof ~
			" occludes successive function" );
		
		foreach ( t2; T[i+1 .. $] )
		{
			alias ParameterTypeTuple!(t2) a2;
			static assert( !is( a1 == a2 ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
			static assert( !isImplicitlyConvertible!( a2, a1 ),
				"case function with argument types " ~ a2.stringof ~
				" is hidden by " ~ a1.stringof );
		}
	}
	foreach (fn; caseFunctions)
	{
		alias ParameterTypeTuple!fn Args;
		if (var.convertsTo!Args)
		{
			return fn(var.get!Args);
		}
	}
	throw new SwitchError("No appropriate switch clause found");
}

unittest
{
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
	Variant var1 = 1;
	Variant var2 = 3.5;
	Variant var3 = "test";
	
	test(var1);
	assert(test2(var1) == 1);
	
	test(var2);
	assert(test2(var2) == 2);
	
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
}


private S indentRuntime(S)(S s, S indentStr = " ")
{
	auto app = appender!(S)();
	// Overflow is no problem for this line.
	app.reserve((s.length * 17)/16);
	
	version (ctfe) if (__ctfe)
	{
		auto lines = s.splitLines(KeepTerminator.yes);
		foreach (l; lines)
		{
			app.put(indentStr);
			app.put(l);
		}
		return app.data;
	}
	
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
	auto app = appender!(S)();
	// Overflow is no problem for this line.
	app.reserve((s.length * 17)/16);
	
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
