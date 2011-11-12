/*******************************************************************************
 * 状態遷移表管理モジュール
 * 
 * このモジュールは状態遷移表に従って遷移する状態を管理するクラスを提供します。
 * イベントをputしてやることによって、コンストラクタなどで指定した状態遷移表
 * に従って状態を遷移させます。
 * 
 * Date: October 31, 2010
 * Authors:
 *     P.Knowledge, SHOO
 * License:
 *     NYSL ( http://www.kmonos.net/nysl/ )
 * 
 */
module voile.stm;


import core.memory;
import std.traits, std.typecons, std.typetuple,
       std.string, std.conv, std.range, std.container, std.signals;


private template isStraight(int start, Em...)
{
	static if (Em.length == 1)
	{
		enum isStraight = Em[0] == start;
	}
	else
	{
		enum isStraight = Em[0] == start && isStraight!(start+1, Em[1..$]);
	}
}


private template isStraightEnum(E)
	if (is(E == enum))
{
	enum isStraightEnum = isStraight!(EnumMembers!(E)[0], EnumMembers!E);
}


private template ToField(Tuple...)
{
	static if (Tuple.length)
	{
		mixin("alias Tuple[0] " ~ Tuple[0].stringof ~ ";");
		mixin ToField!(Tuple[1..$]);
	}
}


/*******************************************************************************
 * イベントハンドラー
 */
alias void delegate() EventHandler;


/// 到達不可能なイベントハンドラー
enum EventHandler forbiddenEvent = cast(EventHandler)null;


/// 無視するイベントハンドラー
@property EventHandler ignoreEvent()
{
	void dg(){}
	return &dg;
}


/// 何もしないイベント(状態遷移のみ)
@property EventHandler doNothingEvent()
{
	void dg(){}
	return &dg;
}


/*******************************************************************************
 * 状態とハンドラーのペア
 * 
 * StateManagerのコンストラクタの引数に渡すために使用する
 */
template SHPair(State)
{
	alias Tuple!(State, EventHandler) SHPair;
}

/*******************************************************************************
 * 状態遷移を管理するクラスです
 */
struct Stm(TState, TEvent, TState defaultStateParam = TState.init)
	if (isStraightEnum!TState && isStraightEnum!TEvent)
{
	
	/***************************************************************************
	 * 状態の型です
	 */
	alias TState State;
	
	/***************************************************************************
	 * イベントの型です
	 */
	alias TEvent Event;
	
	/***************************************************************************
	 * 禁則事項です
	 * 
	 * イベントを処理する際、仕様上発生しえないイベントである場合発生
	 */
	static class ForbiddenHandlingException: Exception
	{
		immutable State state;
		immutable Event event;
		
		
		private this(State s, Event e, string f = __FILE__, size_t l = __LINE__)
		{
			state = s;
			event = e;
			super(format("This handling is forbidden [State = %s, Event = %s]",
				         to!string(state), to!string(event)), f, l);
		}
	}
	
	
	/***************************************************************************
	 * 状態遷移表の欄
	 */
	private struct Cell
	{
		/***********************************************************************
		 * 次の状態
		 * 
		 * デフォルトはデフォルトの状態
		 */
		State next = defaultStateParam;
		
		
		/***********************************************************************
		 * イベントハンドラ
		 * 
		 * デフォルトは到達不可能
		 */
		EventHandler handler;
		
		
		/**********************************************************************
		 * 次の状態とイベントハンドラの設定
		 */
		void set(State nextState, EventHandler eventHandler)
		{
			next = nextState;
			handler = eventHandler;
		}
	}
	
	version (D_Doc)
	{
		/// イベントの総数
		immutable int eventCount;
		/// 状態の総数
		immutable int stateCount;
		/// デフォルトの状態
		immutable State defaultState;
	}
	/***************************************************************************
	 * イベントの総数
	 */
	enum eventCount = EnumMembers!(Event).length;
	
	
	/***************************************************************************
	 * 状態の総数
	 */
	enum stateCount = EnumMembers!(State).length;
	
	
	/***************************************************************************
	 * デフォルトの状態
	 */
	enum defaultState = defaultStateParam;
	
	
	/***************************************************************************
	 * 状態が遷移したときに呼ばれるハンドラ
	 */
	alias void delegate(State oldstate, State newstate) StateChangedCallback;
	
	/***************************************************************************
	 * イベントが実行される直前に呼ばれるハンドラ
	 */
	alias void delegate(Event ev) EventCallback;
	
	/***************************************************************************
	 * 例外発生時に呼ばれるハンドラ
	 */
	alias void delegate(Throwable e) nothrow ExceptionCallback;
	
	
private:
	
	static struct Handler(CallbackFunc)
	{
	private:
		static class Impl
		{
			mixin Signal!(ParameterTypeTuple!CallbackFunc);
		}
		Impl _impl;
	public:
		this(this)
		{
			if (_impl)
			{
				auto old = _impl;
				_impl = new Impl;
				foreach (s; old.slots)
				{
					_impl.connect(s);
				}
			}
		}
		
		void connect(CallbackFunc dg)
		{
			if (!_impl) _impl = new Impl;
			_impl.connect(dg);
		}
		
		void disconnect(CallbackFunc dg)
		{
			assert(_impl);
			_impl.disconnect(dg);
		}
		
		void emit(ParameterTypeTuple!CallbackFunc params)
		{
			if (!_impl) _impl = new Impl;
			_impl.emit(params);
		}
		
		void clear()
		{
			if (_impl)
			{
				.clear(_impl);
				GC.free(cast(void*)_impl);
				_impl = null;
			}
		}
	}
	
	
	// 状態遷移表
	Cell[stateCount][eventCount] _table;
	
	
	// 現在のステート
	State _state = defaultState;
	
	
	// 処理すべきイベントのFIFO
	SList!Event events;
	
	
public:
	
	
	/***************************************************************************
	 * 初期化
	 */
	this(SHPair!(State)[stateCount][eventCount] table...)
	{
		initialize(table);
	}
	
	
	/// ditto
	void initialize(SHPair!(State)[stateCount][eventCount] table...)
	{
		foreach (m; 0..eventCount)
		foreach (n; 0..stateCount)
		{
			_table[m][n].set(table[m][n][0], table[m][n][1]);
		}
		onStateChanged.clear();
		onEvent.clear();
		onException.clear();
	}
	
	
	/***************************************************************************
	 * 現在のステート
	 */
	State currentState()
	{
		return _state;
	}
	
	/***************************************************************************
	 * STMを初期化するためのクラスが返る
	 * 
	 * 以下のような書式にしたがって初期化用のデータを設定する。
	 * 
	 * Examples:
	 *--------------------------------------------------------------------------
	 *class Foo
	 *{
	 *	enum State
	 *	{
	 *		initializing,
	 *		stead,
	 *		disposed
	 *	}
	 *	enum Event
	 *	{
	 *		start,
	 *		changed,
	 *		end
	 *	}
	 *	
	 *	Stm!(State, Event) _stm;
	 *	
	 *	this()
	 *	{
	 *		with (_stm.initializer)
	 *		{
	 *			//          | initializing     | stead         | disposed
	 *			set(start)   (stead,             invalid,        invalid       )
	 *			    =        [doNothing,         forbidden,      forbidden     ];
	 *			
	 *			set(changed) (invalid,           stead,          invalid       )
	 *			    =        [forbidden,         forbidden,      forbidden     ];
	 *			
	 *			set(end)     (disposed,          disposed,       invalid       )
	 *			    =        [doNothing,         doNothing,      forbidden     ];
	 *		}
	 *	}
	 *}
	 *--------------------------------------------------------------------------
	 * この返値はwithとともに使用すると良い。メンバとして以下が使用可能。
	 * $(DL
	 *    $(DT invalid)   $(DD 無効な状態)
	 *    $(DT forbidden) $(DD 到達不可能イベントハンドラ)
	 *    $(DT ignore)    $(DD 無視イベントハンドラ)
	 *    $(DT doNothing) $(DD 特に何もすることはないイベントハンドラ)
	 *    $(DT State.*)   $(DD 状態の一覧はすべてenum名なしでアクセス可能)
	 *    $(DT Event.*)   $(DD イベントの一覧はすべてenum名なしでアクセス可能)
	 *    $(DT set)       $(DD &#40;state1, state2, state3...&#41;な引数をとり、設定する関数。その返値に = でイベントハンドラの配列を渡し、イベントハンドラを設定する)
	 * )
	 */
	@property auto initializer()
	{
		enum Dummy { dummy };
		struct HandlerSetter
		{
			Cell[] cells;
			@disable this();
			@disable static HandlerSetter init();
			@disable this(this);
			private this(Cell[] c){cells = c;}
			void opAssign(EventHandler[stateCount] handlers)
			{
				foreach (i, h; handlers)
				{
					cells[i].handler = h;
				}
			}
		}
		class StateSetter
		{
			private this(Dummy dummy) {  }
			alias doNothingEvent doNothing;
			alias forbiddenEvent forbidden;
			alias ignoreEvent    ignore;
			alias EnumMembers!(State)[0] invalid;
			mixin ToField!(EnumMembers!Event);
			mixin ToField!(EnumMembers!State);
			auto set(Event e)
			{
				auto cells = _table[e][];
				return delegate HandlerSetter(State[] nextstates...)
				{
					assert(nextstates.length == stateCount);
					foreach (i, s; nextstates)
					{
						cells[i].next = s;
					}
					return HandlerSetter(cells[]);
				};
			}
		}
		return new StateSetter(Dummy.dummy);
	}
	
	
	
	/***************************************************************************
	 * イベントの通知
	 */
	void put(string f = __FILE__, size_t l = __LINE__)(Event e)
	{
		if (_table[e][_state].handler is null)
		{
			debug
			{
				throw new ForbiddenHandlingException(_state, e, f, l);
			}
			else
			{
				throw new ForbiddenHandlingException(_state, e);
			}
		}
		if (!events.empty)
		{
			events.insertAfter(events[], e);
			return;
		}
		else
		{
			events.insertAfter(events[], e);
		}
		while (!events.empty)
		{
			try
			{
				auto ev = events.front;
				onEvent.emit(ev);
				_table[ev][_state].handler();
				auto oldstate = _state;
				_state = _table[ev][_state].next;
				onStateChanged.emit(oldstate, _state);
			}
			catch (Throwable e)
			{
				onException.emit(e);
			}
			assert(!events.empty);
			try
			{
				events.removeFront();
			}
			catch (Throwable e)
			{
				assert(0);
			}
		}
	}
	
	
	/***************************************************************************
	 * 状態が変更された際に呼ばれるハンドラを設定/取得する
	 */
	Handler!StateChangedCallback onStateChanged;
	
	
	/***************************************************************************
	 * イベントを処理する際に呼ばれるハンドラを設定/取得する
	 */
	Handler!EventCallback onEvent;
	
	/***************************************************************************
	 * イベントを処理する際に呼ばれるハンドラを設定/取得する
	 */
	Handler!ExceptionCallback onException;
}


template isStm(STM)
{
	static if (is(STM S: Stm!(S, E), E))
	{
		enum isStm = true;
	}
	else
	{
		enum isStm = false;
	}
}


unittest
{
	enum State { a, b }
	enum Event { e1, e2, e3 }
	
	alias SHPair!(State) SH;
	string msg;
	// 状態遷移表
	auto sm = Stm!(State, Event)(
		// イベント  状態A                           状態B
		/* e1:   */ [SH(State.b, {msg = "a-1";}), SH(State.b, forbiddenEvent)],
		/* e2:   */ [SH(State.a, ignoreEvent),    SH(State.a, {msg = "b-2";})],
		/* e3:   */ [SH(State.a, {msg = "a-3";}), SH(State.a, forbiddenEvent)]
	);
	//static assert(isOutputRange!(typeof(sm), Event));
	static assert(isStm!(typeof(sm)));
	static assert(isOutputRange!(typeof(sm), Event));
	
	assert(sm.currentState == State.a);
	std.range.put(sm, Event.e1);
	assert(sm.currentState == State.b);
	assert(msg == "a-1");
	sm.put(Event.e2);
	assert(sm.currentState == State.a);
	assert(msg == "b-2");
	sm.put(Event.e3);
	assert(sm.currentState == State.a);
	assert(msg == "a-3");
	sm.put(Event.e2);
	assert(sm.currentState == State.a);
	assert(msg == "a-3");
	sm.put(Event.e1);
	assert(sm.currentState == State.b);
	assert(msg == "a-1");
}
