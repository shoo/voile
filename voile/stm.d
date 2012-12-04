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
       std.string, std.conv, std.range, std.container,
       std.csv, std.array, std.format, std.algorithm;
import voile.misc;

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
	 * イベントをキャンセルする場合に投げる
	 * 
	 * イベントを処理する際、イベントを無視して状態遷移を行わなくする場合に
	 * 投げる例外です。
	 */
	static class EventCancelException: Exception
	{
		this()
		{
			super(null, __FILE__, __LINE__);
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
	@property State currentState()
	{
		return _state;
	}
	
	
	/***************************************************************************
	 * ステートを強制的に変更
	 */
	@property void enforceState(State sts)
	{
		_state = sts;
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
	 *    $(DT invalid)        $(DD 無効な状態)
	 *    $(DT forbidden)      $(DD 到達不可能イベントハンドラ)
	 *    $(DT ignore)         $(DD 無視イベントハンドラ)
	 *    $(DT doNothing)      $(DD 特に何もすることはないイベントハンドラ)
	 *    $(DT State.*)        $(DD 状態の一覧はすべてenum名なしでアクセス可能)
	 *    $(DT Event.*)        $(DD イベントの一覧はすべてenum名なしでアクセス可能)
	 *    $(DT set)            $(DD &#40;state1, state2, state3...&#41;な引数をとり、設定するデリゲートを返す。
	 *                              その返値に = でイベントハンドラの配列を渡し、イベントハンドラを設定する。)
	 *    $(DT onException)    $(DD onException アクティビティ)
	 *    $(DT onStateChanged) $(DD onStateChanged アクティビティ)
	 *    $(DT onEvent)        $(DD onEvent アクティビティ)
	 * )
	 */
	@property auto initializer()
	{
		enum Dummy { dummy }
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
		alias onException    _onException;
		alias onStateChanged _onStateChanged;
		alias onEvent        _onEvent;
		class StateSetter
		{
			private this(Dummy dummy) {  }
			alias doNothingEvent doNothing;
			alias forbiddenEvent forbidden;
			alias ignoreEvent    ignore;
			alias EnumMembers!(State)[0] invalid;
			mixin ToField!(EnumMembers!Event);
			mixin ToField!(EnumMembers!State);
			ref Handler!(ExceptionCallback)    onException()    @property { return _onException; }
			ref Handler!(StateChangedCallback) onStateChanged() @property { return _onStateChanged; }
			ref Handler!(EventCallback)        onEvent()        @property { return _onEvent; }
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
	void put(Event e)
	{
		if (_table[e][_state].handler is null)
		{
			throw new ForbiddenHandlingException(_state, e);
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
				bool cancel = false;
				try
				{
					onEvent.emit(ev);
					_table[ev][_state].handler();
				}
				catch (EventCancelException e)
				{
					cancel = true;
				}
				if (!cancel)
				{
					auto oldstate = _state;
					_state = _table[ev][_state].next;
					onStateChanged.emit(oldstate, _state);
				}
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
	Handler!(StateChangedCallback) onStateChanged;
	
	
	/***************************************************************************
	 * イベントを処理する際に呼ばれるハンドラを設定/取得する
	 */
	Handler!(EventCallback) onEvent;
	
	/***************************************************************************
	 * イベントを処理する際に呼ばれるハンドラを設定/取得する
	 */
	Handler!(ExceptionCallback) onException;
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



private struct CsvStmParsedData
{
	string[string] map;
	
	string[]       statesRaw;
	string[]       eventsRaw;
	string[][]     cellsRaw;
	string[]       stactsRaw;
	string[]       edactsRaw;
	
	string[]       states;
	string[]       events;
	string[][][]   procs;
	string[][]     nextsts;
	string[][]     stacts;
	string[][]     edacts;
	
	// 状態の書き出し。 State という名前の enum を書き出す
	void makeEnumStates(Range)(ref Range srcstr)
	{
		auto app = appender!(string[])();
		foreach (s; statesRaw)
		{
			auto str = map.get(s, s);
			if (str.length)
				app.put( str );
		}
		
		states = app.data;
		
		srcstr.put("enum State\n{\n");
		srcstr.formattedWrite("%-(\t%s, \n%)", states);
		srcstr.put("\n}\n");
	}
	
	// イベントの書き出し。 Event という名前の enum を書き出す。
	void makeEnumEvents(Range)(ref Range srcstr)
	{
		auto app = appender!(string[])();
		foreach (s; eventsRaw)
		{
			auto str = map.get(s, s);
			if (str.length)
				app.put( str );
		}
		
		events = app.data;
		
		srcstr.put("enum Event\n{\n");
		srcstr.formattedWrite("%-(\t%s, \n%)", events);
		srcstr.put("\n}\n");
	}
	
	private static void replaceProcContents(Range)(ref Range srcstr, ref string[] procs, string[string] map)
	{
		auto app = appender!(string[])();
		foreach (s; procs)
		{
			auto str = map.get(s, s);
			if (str.length)
				app.put( str );
		}
		procs = app.data;
	}
	
	// 
	void makeProcs(Range)(ref Range srcstr)
	{
		procs   = new string[][][](events.length, states.length, 0);
		nextsts = new string[][](events.length, states.length);
		foreach (i, rows; cellsRaw)
		{
			foreach (j, cell; rows)
			{
				auto lines = cell.splitLines();
				string nextState;
				string[] proclines;
				if (lines.length && lines[0].startsWith("▽"))
				{
					nextState = map.get(lines[0], lines[0]);
					assert(nextState.length);
					proclines = lines[1..$];
				}
				else
				{
					nextState = states[j];
					proclines = lines;
				}
				
				replaceProcContents(srcstr, proclines, map);
				procs[i][j] = proclines;
				nextsts[i][j] = nextState;
				if (proclines.length == 0 || proclines[0] == "x")
				{
					continue;
				}
				srcstr.formattedWrite("void _stmProcE%dS%d()\n{\n", i, j);
				srcstr.formattedWrite("%-(\t%s\n%)", proclines);
				srcstr.put("\n}\n");
			}
		}
	}
	
	// アクティビティ用の関数を作成する _stmStEdActivity という関数名で作成
	void makeActivities(Range)(ref Range srcstr)
	{
		auto apped = appender!string();
		auto appst = appender!string();
		
		stacts.length = stactsRaw.length;
		edacts.length = edactsRaw.length;
		
		appst.put("\tswitch (newsts)\n\t{\n");
		foreach (i, act; stactsRaw)
		{
			auto proclines = act.splitLines();
			if (proclines.length == 0)
				continue;
			auto name = xformat("_stmStartActS%d", i);
			srcstr.put("void ");
			srcstr.put(name);
			srcstr.put("()\n{\n");
			replaceProcContents(srcstr, proclines, map);
			srcstr.formattedWrite("%-(\t%s\n%)", proclines);
			srcstr.put("\n}\n");
			appst.formattedWrite(
				"\tcase cast(typeof(newsts))%d:\n"
				"\t\t%s();\n"
				"\t\tbreak;\n", i, name);
			stacts[i] = proclines;
		}
		appst.put(
			"\tdefault:\n"
			"\t}\n");
		
		apped.put("\tswitch (oldsts)\n\t{\n");
		foreach (i, act; edactsRaw)
		{
			auto proclines = act.splitLines();
			if (proclines.length == 0)
				continue;
			auto name = xformat("_stmEndActS%d", i);
			srcstr.put("void ");
			srcstr.put(name);
			srcstr.put("()\n{\n");
			replaceProcContents(srcstr, proclines, map);
			srcstr.formattedWrite("%-(\t%s\n%)", proclines);
			srcstr.put("\n}\n");
			apped.formattedWrite(
				"\tcase cast(typeof(oldsts))%d:\n"
				"\t\t%s();\n"
				"\t\tbreak;\n", i, name);
			edacts[i] = proclines;
		}
		apped.put(
			"\tdefault:\n"
			"\t}\n");
		if (appst.data.length != 0 || apped.data.length != 0)
		{
			srcstr.put(
				"void _onStEdActivity(State oldsts, State newsts)\n"
				"{\n"
				"\tif (oldsts == newsts)\n"
				"\t\treturn;\n");
			srcstr.put( apped.data );
			srcstr.put( appst.data );
			srcstr.put("}\n");
		}
	}
	
	
	// 
	void makeFactory(Range)(ref Range srcstr)
	{
		auto app = appender!(string[][])();
		auto app2 = appender!(string[])();
import std.stdio;		
		foreach (i; 0..events.length)
		{
			app2.shrinkTo(0);
			foreach (j; 0..states.length)
			{
				string proc;
				if (procs[i][j].length == 0)
				{
					proc = "ignoreEvent";
				}
				else if (procs[i][j].length == 1 && procs[i][j][0] == "x")
				{
					proc = "forbiddenEvent";
				}
				else
				{
					proc = xformat("&_stmProcE%dS%d", i, j);
				}
				app2.put(xformat("SH(State.%s, %s)", nextsts[i][j], proc));
			}
			app.put(app2.data.dup);
		}
		
		srcstr.formattedWrite(
			"Stm!(State, Event) stmFactory()\n"
			"{\n"
			"\talias SHPair!(State) SH;\n"
			"\tauto stm = Stm!(State, Event)(\n"
			"\t\t%([%-(%s, %)]%|, \n\t\t%));\n", app.data);
		alias reduce!"a | (b.length != 0)" existsAct;
		if (existsAct(false, stacts) || existsAct(false, edacts))
		{
			srcstr.put("\tstm.onStateChanged ~= &_onStEdActivity;\n");
		}
		srcstr.put(
			"\treturn stm;\n"
			"}\n");
	}
	
}
/*******************************************************************************
 * スプレッドシート(CSV)で記述されたSTMをD言語コードへ変換する
 * 
 * このCSVによるSTMは以下のルールに従って変換される。
 * $(UL
 *   $(LI CSVの1行目は状態を記述する)
 *   $(LI 「状態」は必ず▽で始まる文字列を指定する)
 *   $(LI CSVの2行目は「スタートアクティビティ」を記述する)
 *   $(LI CSVの3行目は「エンドアクティビティ」を記述する)
 *   $(LI スタートアクティビティとエンドアクティビティには「処理」を記述する)
 *   $(LI スタートアクティビティは状態が遷移した際に、遷移後の状態の最初に実行される)
 *   $(LI エンドアクティビティは状態が遷移した際に、遷移前の状態の最後に実行される)
 *   $(LI CSVの1から3行目の1列目は無視される)
 *   $(LI CSVの4行目以降の1列目は「イベント」を記述する)
 *   $(LI CSVの4行目以降は「セル」としてイベント発生時の「状態遷移」と「処理」を記述する)
 *   $(LI セルは複数行にわたって記述することができる)
 *   $(LI 状態遷移はセルの先頭行に▽で始まる状態名を指定する)
 *   $(LI 空白のセルはイベント処理の無視を意味する)
 *   $(LI x とだけ記述されたセルはイベント処理の禁止表明を意味する)
 * )
 * また、第二引数は置換情報を指定するCSVが記述された文字列を指定する。
 * $(UL
 *   $(LI 置換用CSVの置換対象はSTMの「状態」と「イベント」と「状態遷移」と「処理」)
 *   $(LI CSVの1列目は変換前の文字列を記述する)
 *   $(LI CSVの2列目は変換後の文字列を記述する)
 * )
 * 
 * この関数により生成される文字列はD言語のソースコードで、実際のコードに埋め込むか、
 * mixin()によって使用することが可能になります。$(BR)
 * 状態は $(D State) という名前の列挙体として生成されます。$(BR)
 * イベントは $(D Event) という名前の列挙体として生成されます。$(BR)
 * 生成されたFactory関数を実行することでSTMが生成されます。$(BR)
 * $(D Stm!(State, Event) stmFactory(); )$(BR)
 *Examples:
 *------------------------------------------------------------------------------
 *enum stmcode = parseCsvStm(stmcsv, replaceData);
 *mixin(stmcode);
 *auto stm = stmFactory();
 *------------------------------------------------------------------------------
 *Examples:
 * test.stm.csv
 * $(TABLE
 *   $(TR $(TH )                           $(TH ▽初期)   $(TH ▽接続中)       $(TH ▽通信中) $(TH ▽切断中) )
 *   $(TR $(TH スタートアクティビティ)     $(TD )         $(TD 接続要求を開始) $(TD )         $(TD 切断要求を開始) )
 *   $(TR $(TH エンドアクティビティ)       $(TD )         $(TD 接続要求を停止) $(TD )         $(TD 切断要求を停止) )
 *   $(TR $(TH 接続の開始指示を受けたら)   $(TD ▽接続中) $(TD )               $(TD x)        $(TD x) )
 *   $(TR $(TH 接続の停止指示を受けたら)   $(TD )         $(TD ▽切断中)       $(TD ▽切断中) $(TD ) )
 *   $(TR $(TH 通信が開始されたら)         $(TD ▽切断中) $(TD ▽通信中)       $(TD x)        $(TD x) )
 *   $(TR $(TH 通信が切断されたら)         $(TD x)        $(TD ▽初期)         $(TD ▽初期)   $(TD ▽初期) )
 * )
 * test.gcd.csv
 * $(TABLE
 *   $(TR $(TD ▽初期)   $(TD init) )
 *   $(TR $(TD ▽接続中) $(TD connectBeginning) )
 *   $(TR $(TD ▽通信中) $(TD connecting) )
 *   $(TR $(TD ▽切断中) $(TD connectClosing) )
 *   $(TR $(TD 通信が開始されたら )$(TD openedConnection) )
 *   $(TR $(TD 通信が切断されたら )$(TD closedConnection) )
 *   $(TR $(TD 接続の開始指示を受けたら )$(TD openConnection) )
 *   $(TR $(TD 接続の停止指示を受けたら )$(TD closeConnection) )
 *   $(TR $(TD 接続要求を開始 )$(TD startBeginConnect();) )
 *   $(TR $(TD 接続要求を停止 )$(TD endBeginConnect();) )
 *   $(TR $(TD 切断要求を開始 )$(TD startCloseConnect();) )
 *   $(TR $(TD 切断要求を停止 )$(TD endCloseConnect();) )
 * )
 *------------------------------------------------------------------------------
 *class Foo
 *{
 *private:
 *    void startBeginConnect()
 *    {
 *        writeln("startBeginConnect");
 *    }
 *    void endBeginConnect()
 *    {
 *        writeln("endBeginConnect");
 *    }
 *    void startCloseConnect()
 *    {
 *        writeln("startCloseConnect");
 *    }
 *    void endCloseConnect()
 *    {
 *        writeln("endCloseConnect");
 *    }
 *    
 *    mixin(parseCsvStm(import("test.stm.csv"), import("test.gcd.csv")));
 *public:
 *    Stm!(State, Event) stm;
 *    alias stm this;
 *    this()
 *    {
 *        stm = stmFactory();
 *    }
 *}
 *------------------------------------------------------------------------------
 */
string parseCsvStm(string csvstm, string csvmap = "")
{
	auto app = appender!(string[][])();
	foreach (data; csvReader!(string)(csvstm))
	{
		app.put(array(data).dup);
	}
	static struct Layout
	{
		string key;
		string val;
	}
	string[string] map;
	foreach (data; csvReader!Layout(csvmap))
	{
		map[data.key] = data.val;
	}
	CsvStmParsedData pd;
	pd.map = map;
	pd.statesRaw = app.data[0][1..$];
	pd.stactsRaw = app.data[1][1..$];
	pd.edactsRaw = app.data[2][1..$];
	pd.eventsRaw.length = app.data.length-3;
	pd.cellsRaw.length = app.data.length-3;
	foreach (i, r; app.data[3..$])
	{
		pd.eventsRaw[i] = r[0];
		pd.cellsRaw[i]  = r[1..$];
	}
	
	auto srcstr = appender!string();
	pd.makeEnumStates(srcstr);
	pd.makeEnumEvents(srcstr);
	pd.makeActivities(srcstr);
	pd.makeProcs(srcstr);
	pd.makeFactory(srcstr);
	return srcstr.data();
}


unittest
{
enum stmcsv = `,▽初期,▽接続中,▽通信中,▽切断中
スタートアクティビティ,,接続要求を開始,,切断要求を開始
エンドアクティビティ,,接続要求を停止,,切断要求を停止
接続の開始指示を受けたら,▽接続中,,x,x
接続の停止指示を受けたら,,▽切断中,▽切断中,
通信が開始されたら,▽切断中,▽通信中,x,x
通信が切断されたら,x,▽初期,▽初期,▽初期`;

enum replaceData = `▽初期,init
▽接続中,connectBeginning
▽通信中,connecting
▽切断中,connectClosing
通信が開始されたら,openedConnection
通信が切断されたら,closedConnection
接続の開始指示を受けたら,openConnection
接続の停止指示を受けたら,closeConnection
接続要求を開始,startBeginConnect();
接続要求を停止,endBeginConnect();
切断要求を開始,startCloseConnect();
切断要求を停止,endCloseConnect();`;

	enum stmcode = parseCsvStm(stmcsv, replaceData);
	int x;
	void startBeginConnect()
	{
		x = 1;
	}
	void endBeginConnect()
	{
		x = 2;
	}
	void startCloseConnect()
	{
		x = 3;
	}
	void endCloseConnect()
	{
		x = 4;
	}
	
	mixin(stmcode);
	auto stm = stmFactory();
	assert(stm._table[Event.openConnection][State.init].handler !is null);
	assert(x == 0);
	stm.put(Event.openConnection);
	assert(x == 1);
	assert(stm.currentState == State.connectBeginning);
	stm.put(Event.openedConnection);
	assert(x == 2);
	assert(stm.currentState == State.connecting);
	stm.put(Event.closeConnection);
	assert(x == 3);
	assert(stm.currentState == State.connectClosing);
	stm.put(Event.closedConnection);
	assert(x == 4);
	assert(stm.currentState == State.init);
}

