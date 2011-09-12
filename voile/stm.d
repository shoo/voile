﻿/*******************************************************************************
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


import std.traits, std.typecons, std.typetuple,
       std.string, std.conv, std.range, std.container;


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



/*******************************************************************************
 * イベントハンドラー
 */
alias void delegate() EventHandler;


/// 到達不可能なイベントハンドラー
enum EventHandler forbiddenEvent = cast(EventHandler)null;


/// 無視するイベントハンドラー
EventHandler ignoreEvent()
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
	
	
private:
	
	
	// 状態遷移表
	Cell[stateCount][eventCount] _table;
	
	
	// 現在のステート
	State _state = defaultState;
	
	
	// 処理すべきイベントのFIFO
	SList!Event events;
	
	// 状態が変更されたときに呼ばれるハンドラ
	StateChangedCallback _onStateChanged;
	
	
	// イベントが処理される直前に呼ばれるハンドラ
	EventCallback _onEvent;
	
	
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
	}
	
	
	/***************************************************************************
	 * 現在のステート
	 */
	State currentState()
	{
		return _state;
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
			auto ev = events.front;
			if (_onEvent) _onEvent(ev);
			events.removeFront();
			_table[ev][_state].handler();
			auto oldstate = _state;
			_state = _table[ev][_state].next;
			if (_onStateChanged && _state != oldstate)
			{
				_onStateChanged(oldstate, _state);
			}
		}
	}
	
	
	/***************************************************************************
	 * 状態が変更された際に呼ばれるハンドラを設定/取得する
	 */
	@property
	void stateChangedCallback(StateChangedCallback dg)
	{
		_onStateChanged = dg;
	}
	
	/// ditto
	@property
	StateChangedCallback stateChangedCallback()
	{
		return _onStateChanged;
	}
	
	
	/***************************************************************************
	 * イベントを処理する際に呼ばれるハンドラを設定/取得する
	 */
	@property
	void eventCallback(EventCallback dg)
	{
		_onEvent = dg;
	}
	
	
	/// ditto
	@property
	EventCallback eventCallback()
	{
		return _onEvent;
	}
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
	static assert(isOutputRange!(typeof(sm), Event));
	static assert(isStm!(typeof(sm)));
	
	assert(sm.currentState == State.a);
	sm.put(Event.e1);
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
