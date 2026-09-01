/*******************************************************************************
 * sync モジュール
 * 
 * よく使う同期用クラスのインターフェースを利用可能。
 * $(UL
 *     $(LI Light )
 *     $(LI NamedMutex )
 * )
 * 
 * Date: July 29, 2009
 * Authors:
 *     P.Knowledge, SHOO
 * License:
 *     NYSL ( http://www.kmonos.net/nysl/ )
 * 
 */
module voile.sync;


import core.thread, core.sync.mutex, core.sync.condition, core.sync.event, core.atomic;
version (Windows)
{
	import core.sys.windows.windows;
}
import std.traits, std.parallelism;

public import voile.misc: assumeUnshared, assumeShared;

/*******************************************************************************
 * 同期イベントクラス
 * 
 * Windowsの CreateEvent や SetEvent のラッパー
 * Windows以外の環境でも動作するが、最適な実装ではないかもしれない。
 * Example:
 *------------------------------------------------------------------------------
 *SyncEvent[3] ev;
 *int data;
 *void run1()
 *{
 *	data = 1;
 *	ev[0].signal = true;
 *}
 *
 *void run2()
 *{
 *	data = 2;
 *	ev[1].signal = true;
 *}
 *
 *void run3()
 *{
 *	data = 3;
 *	ev[2].signal = true;
 *}
 *void main()
 *{
 *	ev[] = [new Light, new Light, new Light];
 *	scope t = new ThreadGroup;
 *	data = 0;
 *	t.create(&run1);
 *	ev[0].wait;
 *	assert(data == 1);
 *	data = 0;
 *	t.create(&run2);
 *	ev[1].wait;
 *	assert(data == 2);
 *	data = 0;
 *	t.create(&run3);
 *	ev[2].wait;
 *	assert(data == 3);
 *}
 *------------------------------------------------------------------------------
 */
class SyncEvent
{
	version(Windows)
	{
		private static HANDLE createEvent(bool aFirstCondition = false) nothrow @nogc
		{
			auto h = CreateEventW(null, 1, aFirstCondition ? 1 : 0, null);
			return h;
		}
		private static void closeEvent(HANDLE h) nothrow @nogc
		{
			CloseHandle(h);
		}
		private HANDLE _handle = null;
		private const bool _ownHandle;
		/***********************************************************************
		 * ハンドルを得る
		 * 
		 * ただしOS依存する処理をする場合にのみ使用すること
		 */
		HANDLE handle()
		{
			return _handle;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: h = イベントハンドル
		 */
		this(HANDLE h) pure nothrow @nogc
		{
			_ownHandle = false;
			_handle = h;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: firstCondition = 初期状態
		 */
		this(bool firstCondition = false) nothrow @nogc
		{
			_ownHandle = true;
			_handle = createEvent(firstCondition);
		}
		/// ditto
		this(bool firstCondition = false) shared nothrow @nogc
		{
			_ownHandle = true;
			(cast()this)._handle = createEvent(firstCondition);
		}
		/***********************************************************************
		 * シグナル状態を返す
		 * 
		 * Returns:
		 *     trueならシグナル状態で、waitはすぐに制御を返す
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるか、時間が
		 *     過ぎるまで制御を返さない状態であることを示す。
		 */
		@property bool signaled() nothrow @nogc
		{
			return WaitForSingleObject(_handle, 0) == WAIT_OBJECT_0;
		}
		/// ditto
		@property bool signaled() shared nothrow @nogc
		{
			return (cast()this).signaled;
		}
		/***********************************************************************
		 * シグナル状態を設定する
		 * 
		 * Params: cond=
		 *     trueならシグナル状態にし、waitしているスレッドの制御を返す。
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるまで制御を
		 *     返さない状態にする。
		 */
		@property void signaled(bool cond) nothrow @nogc
		{
			if (cond == true && signaled == false)
			{
				SetEvent(_handle);
			}
			else if (cond == false && signaled == true)
			{
				ResetEvent(_handle);
			}
		}
		/// ditto
		@property void signaled(bool cond) shared nothrow @nogc
		{
			(cast()this).signaled = cond;
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるまで制御を
		 * 返さない。
		 */
		void wait() nothrow @nogc const
		{
			WaitForSingleObject(cast(HANDLE)_handle, INFINITE);
		}
		/// ditto
		void wait() const shared
		{
			(cast()this).wait();
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(Duration dir) nothrow @nogc const
		{
			return WaitForSingleObject(cast(HANDLE)_handle, cast(uint)dir.total!"msecs")
				== WAIT_OBJECT_0;
		}
		/// ditto
		bool wait(Duration dur) const shared
		{
			return (cast()this).wait(dur);
		}
		~this()
		{
			if ( _ownHandle )
			{
				closeEvent(_handle);
				_handle = null;
			}
		}
	}
	else
	{
		private Condition _condition;
		private Mutex _mutex;
		private bool _signaled;
		/***********************************************************************
		 * ハンドルを得る
		 * 
		 * ただしOS依存する処理をする場合にのみ使用すること
		 */
		@property Condition handle()
		{
			return _condition;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: firstCondition = 初期状態
		 */
		this(bool firstCondition = false)
		{
			_signaled = firstCondition;
			_mutex = new Mutex;
			_condition = new Condition(_mutex);
		}
		/// ditto
		this(bool firstCondition = false) shared
		{
			(cast()this)._signaled = firstCondition;
			(cast()this)._mutex = new Mutex;
			(cast()this)._condition = new Condition(cast()_mutex);
		}
		/***********************************************************************
		 * シグナル状態を返す
		 * 
		 * Returns:
		 *     trueならシグナル状態で、waitはすぐに制御を返す
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるか、時間が
		 *     過ぎるまで制御を返さない状態であることを示す。
		 */
		@property bool signaled()
		{
			synchronized (_mutex)
				return _signaled;
		}
		/// ditto
		@property bool signaled() shared
		{
			return (cast()this).signaled;
		}
		/***********************************************************************
		 * シグナル状態を設定する
		 * 
		 * Params: cond=
		 *     trueならシグナル状態にし、waitしているスレッドの制御を返す。
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるまで制御を
		 *     返さない状態にする。
		 */
		@property void signaled(bool cond)
		{
			synchronized (_mutex)
			{
				_signaled = cond;
				_condition.notifyAll;
			}
		}
		/// ditto
		@property void signaled(bool cond) shared
		{
			return (cast()this).signaled = cond;
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるまで制御を
		 * 返さない。
		 */
		void wait() const
		{
			synchronized (_mutex)
			{
				while (! _signaled)
					(cast()_condition).wait();
			}
		}
		/// ditto
		void wait() const shared
		{
			(cast()this).wait();
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(Duration dur)
		{
			synchronized (_mutex)
			{
				while (! _signaled)
					_condition.wait(dur);
				return _signaled;
			}
		}
		/// ditto
		bool wait(Duration dur) const shared
		{
			return (cast()this).wait(dur);
		}
	}
}

@system unittest
{
	int data;
	SyncEvent[3] ev;
	void run1()
	{
		data = 1;
		ev[0].signaled = true;
	}
	
	void run2()
	{
		data = 2;
		ev[1].signaled = true;
	}
	
	void run3()
	{
		data = 3;
		ev[2].signaled = true;
	}
	ev[] = [new SyncEvent, new SyncEvent, new SyncEvent];
	scope t = new ThreadGroup;
	data = 0;
	t.create(&run1);
	ev[0].wait();
	assert(data == 1);
	data = 0;
	t.create(&run2);
	ev[1].wait();
	assert(data == 2);
	data = 0;
	t.create(&run3);
	ev[2].wait();
	assert(data == 3);
}


version (Windows) HANDLE handle(ref Event e) @system @property
{
	return *cast(HANDLE*)&e;
}
version (Windows) @system unittest
{
	import core.sys.windows.windows;
	Event e;
	e.initialize(true, true);
	auto res = ResetEvent(e.handle);
	assert(res != FALSE);
	assert(GetLastError() == 0);
	e.terminate();
}

version (Posix)
{
	private import core.sys.posix.semaphore;
	private import core.sys.posix.fcntl;
	private import core.sys.posix.sys.stat: S_IRWXU, S_IRWXG, S_IRWXO;
	private static const s777 = S_IRWXU|S_IRWXG|S_IRWXO;
	private import core.stdc.errno;
	private alias HANDLE = sem_t*;
}
else version (Windows)
{
	private extern (Windows) HANDLE CreateMutexW(void*, int, const wchar*) nothrow @nogc;
	private extern (Windows) int ReleaseMutex(const HANDLE) nothrow @nogc;
}
else
{
	static assert(0, "Posix or Windows only");
}

/*******************************************************************************
 * 名前付きミューテックス
 * 
 * プロセス間で共有される名前付きミューテックスの作成を行う。
 */
class NamedMutex: Object.Monitor
{
private:
	static struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy m_Proxy;
	HANDLE _handle;
	string m_Name;
	version (Posix) string m_SavedName;
public:
	/***************************************************************************
	 * コンストラクタ
	 * 
	 * Params:
	 *     aName=名前付きミューテックスの名前を指定する。名前は128文字以内。
	 */
	this(string aName)
	{
		assert(aName.length < 750);
		m_Proxy.link = this;
		this.__monitor = &m_Proxy;
		m_Name = aName;
		version (Posix)
		{
			alias char_t = char;
		}
		else version (Windows)
		{
			alias char_t = wchar;
		}
		char_t[1024*4] buf;
		static char_t[] encodeStr(string str, char_t[] aBuf)
		{
			auto dBuf = aBuf;
			dBuf[0..(cast(char_t[])"/voile::NamedMutex[").length] = cast(char_t[])"/voile::NamedMutex[";
			size_t j=(cast(char_t[])"/voile::NamedMutex[").length;
			foreach (char c; str)
			{
				switch (c)
				{
				case '%':
					dBuf[j++] = '%';
					dBuf[j++] = '%';
					break;
				case '\\':
					dBuf[j++] = '%';
					dBuf[j++] = '5';
					dBuf[j++] = 'c';
					break;
				case '/':
					dBuf[j++] = '%';
					dBuf[j++] = '2';
					dBuf[j++] = 'f';
					break;
				default:
					dBuf[j++] = c;
					break;
				}
			}
			if (j + 1 >= dBuf.length)
				dBuf.length = dBuf.length + 2;
			dBuf[j++] = ']';
			dBuf[j++] = '\0';
			return dBuf[0..j];
		}
		version (Posix)
		{
			auto tmpname = m_SavedName = cast(string)encodeStr(name, buf);
		}
		else
		{
			auto tmpname = encodeStr(name, buf);
		}
		if (tmpname.length >= 250)
		{
			throw new Exception("名前が長すぎます");
		}
		
		version (Posix)
		{
			_handle = sem_open(tmpname.ptr, O_CREAT, s777, 1);
		}
		else version (Windows)
		{
			_handle = CreateMutexW(null, 0, tmpname.ptr);
		}
	}
	
	/***************************************************************************
	 * 名前を返す。
	 */
	string name() pure nothrow @safe @nogc const @property
	{
		return m_Name;
	}
	
	/***************************************************************************
	 * デストラクタ
	 * 
	 * 名前付きミューテックスの削除を行う
	 */
	~this() nothrow @nogc
	{
		this.__monitor = null;
		version (Posix)
		{
			sem_close(_handle);
			sem_unlink(m_SavedName.ptr);
		}
		else version (Windows)
		{
			CloseHandle(_handle);
		}
	}
	/***************************************************************************
	 * ロックする
	 * 
	 * ロックが成功するまで制御は返らない
	 */
	void lock() nothrow @nogc
	{
		version (Posix)
		{
			sem_wait(_handle);
		}
		else version (Windows)
		{
			WaitForSingleObject(_handle, 0xffffffff);
		}
	}
	/***************************************************************************
	 * ロックの試行
	 * 
	 * 即座に制御が返る。
	 * trueが帰った場合ロックが成功している。
	 * falseなら別のMutexにロックされているため、ロックされなかった。
	 */
	bool tryLock() nothrow @nogc
	{
		version (Posix)
		{
			return sem_trywait(_handle) == 0;
		}
		else version (Windows)
		{
			return WaitForSingleObject(_handle, 0) == 0;
		}
	}
	/***************************************************************************
	 * ロック解除
	 */
	void unlock() nothrow @nogc
	{
		version (Posix)
		{
			sem_post(_handle);
		}
		else version (Windows)
		{
			cast(void)ReleaseMutex(_handle);
		}
	}
}




private template QueuedSemImpl()
{
private:
	import core.sync.mutex, core.sync.semaphore;
	Semaphore[]  _sems;
	Mutex        _mutex;
	size_t       _count;
	
	void _lockImpl()
	{
		import std.algorithm, std.array;
		Semaphore s;
		synchronized (_mutex)
		{
			if (_count == 0)
			{
				s = new Semaphore;
				_sems ~= s;
			}
			else
			{
				_count--;
				return;
			}
		}
		s.wait();
	}
	
	bool _tryLockImpl()
	{
		synchronized (_mutex)
		{
			if (_count == 0)
				return false;
			_count--;
		}
		return true;
	}
	
	void _unlockImpl()
	{
		synchronized (_mutex)
		{
			if (_sems.length == 0)
			{
				_count++;
			}
			else
			{
				_sems[0].notify();
				_sems = _sems[1..$];
			}
		}
	}
	
	void _initialize(size_t cnt)
	{
		_count = cnt;
		_mutex = new Mutex;
	}
}

/*******************************************************************************
 * 
 */
class QueuedMutex: Object.Monitor
{
private:
	struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy _proxy;
	mixin QueuedSemImpl;
public:
	///
	this()
	{
		_initialize(1);
		_proxy.link = this;
		this.__monitor = cast(void*)&_proxy;
	}
	///
	this() shared
	{
		(cast()this)._initialize(1);
		_proxy.link = this;
		this.__monitor = cast(void*)&_proxy;
	}
	
	
	///
	void lock() @trusted
	{
		_lockImpl();
	}
	
	///
	void lock() @trusted shared
	{
		(cast()this)._lockImpl();
	}
	
	///
	bool tryLock() @trusted
	{
		return _tryLockImpl();
	}
	
	///
	bool tryLock() @trusted shared
	{
		return (cast()this)._tryLockImpl();
	}
	
	///
	void unlock() @trusted
	{
		_unlockImpl();
	}
	
	///
	void unlock() @trusted shared
	{
		(cast()this)._unlockImpl();
	}
	
}



/*******************************************************************************
 * 
 */
class QueuedSemaphore
{
private:
	mixin QueuedSemImpl;
public:
	///
	this(size_t count = 0)
	{
		_initialize(count);
	}
	///
	this(size_t count = 0) shared
	{
		(cast()this)._initialize(count);
	}
	
	///
	void wait() @trusted
	{
		_lockImpl();
	}
	
	///
	void wait() @trusted shared
	{
		(cast()this)._lockImpl();
	}
	
	///
	bool tryWait() @trusted
	{
		return _tryLockImpl();
	}
	
	///
	bool tryWait() @trusted shared
	{
		return (cast()this)._tryLockImpl();
	}
	
	///
	void notify() @trusted
	{
		_unlockImpl();
	}
	
	///
	void notify() @trusted shared
	{
		(cast()this)._unlockImpl();
	}
	
}


/***************************************************************************
 * タスクの例外処理
 */
private void _execTaskOnFailed(Fut)(Fut future, Exception e)
{
	import std.algorithm: move;
	Fut.FailedHandler call;
	synchronized (future)
	{
		call = future._onFailed.move();
		future._resultException = e;
		future._type = Fut.FinishedType.failed;
	}
	call(e);
	throw e;
}

/***************************************************************************
 * タスクの異常処理
 */
private void _execTaskOnFatal(Fut)(Fut future, Throwable e)
{
	import std.algorithm: move;
	Fut.FatalHandler call;
	synchronized (future)
	{
		call = future._onFatal.move();
		future._resultFatal = e;
		future._type = Fut.FinishedType.fatal;
	}
	call(e);
	throw e;
}


/***************************************************************************
 * タスクを生成する
 */
private void _makeTask(alias func, Fut, Args...)(Fut future, Args args)
{
	import std.algorithm: move;
	alias Ret = Fut.ResultType;
	synchronized (future)
	{
		future._type = Fut.FinishedType.none;
		future._resultException = null;
	}
	auto dg = ()
	{
		try
		{
			static if (is(Ret == void))
			{
				Fut.FinishedHandler call;
				func(args);
				synchronized (future)
				{
					call = future._onFinished.move();
					future._type = Fut.FinishedType.done;
				}
				call();
				return;
			}
			else
			{
				Fut.FinishedHandler call;
				future._resultRaw() = func(args);
				synchronized (future)
				{
					call = future._onFinished.move();
					future._type = Fut.FinishedType.done;
				}
				call(future._resultRaw);
				return future._resultRaw;
			}
		}
		catch (Exception e)
		{
			_execTaskOnFailed(future, e);
		}
		catch (Throwable e)
		{
			_execTaskOnFatal(future, e);
		}
		assert(0);
	};
	future._task = task(dg);
}


private auto _dgRun(F, Args...)(F dg, Args args)
{
	return dg(args);
}


/*******************************************************************************
 * `T` が `Future!X` のインスタンスかどうかを判定する(`then()`の
 * コールバックがFutureを返した場合の自動フラット化=chainingに使用)
 */
private enum isFutureInstance(T) = isInstanceOf!(Future, T);
/// ditto
private alias FutureResultType(T) = TemplateArgsOf!T[0];

/*******************************************************************************
 * 
 */
final class Future(Ret)
{
	import voile.handler;
	alias TaskFunc = Ret delegate();
	alias TaskType = typeof(task(TaskFunc.init));
	alias ResultType = Ret;
	static if (is(Ret == void))
	{
		alias CallbackType = void delegate();
	}
	else
	{
		alias CallbackType = void delegate(ref ResultType res);
	}
	alias CallbackFailedType = void delegate(Exception) nothrow;
	alias CallbackFatalType  = void delegate(Throwable) nothrow;
	alias FinishedHandler    = Handler!CallbackType;
	alias FailedHandler      = Handler!CallbackFailedType;
	alias FatalHandler       = Handler!CallbackFatalType;
private:
	FinishedHandler _onFinished;
	FailedHandler   _onFailed;
	FatalHandler    _onFatal;
	TaskType        _task;
	TaskPool        _taskPool;
	SyncEvent       _evStart;
	
	enum FinishedType
	{
		none, done, failed, fatal
	}
	
	FinishedType _type;
	union
	{
		Exception _resultException;
		Throwable _resultFatal;
	}
	
	static if (is(Ret == void))
	{
		void _resultRaw() inout @property
		{
			// 何もしない
		}
	}
	else
	{
		ref inout(ResultType) _resultRaw() inout @property
		{
			return *cast(inout(ResultType)*)&(cast(Future)this)._task.fixRef((cast(Future)this)._task.returnVal);
		}
	}
	
	void _submit(TaskPool pool)
	{
		// ワーカースレッドが1つも無いプールにキューイングしても
		// (誰かが明示的にそのタスクへ .yieldForce() 等を呼ばない限り)
		// 永久に実行されないため、その場合は新規スレッドでの実行にフォールバックする。
		if (pool.size == 0)
			_task.executeInNewThread();
		else
		{
			_taskPool = pool;
			pool.put(_task);
		}
	}
	
	/***************************************************************************
	 * タスクを介さずに、直接値/例外/致命的エラーで確定させる。
	 * `then()`のコールバックが`Future`を返した場合の自動フラット化(chaining)、
	 * すなわち内側の`Future`が確定した際に外側の`Future`(`this`)へ結果を
	 * 伝播させるために使用する。
	 */
	static if (!is(Ret == void))
	{
		void _settleDone()(auto ref ResultType val)
		{
			import std.algorithm: move;
			synchronized (this)
			{
				if (_task is null)
				{
					static assert(isPointer!TaskType);
					_task = new PointerTarget!TaskType;
					static if (is(typeof(_task.returnVal) == ResultType*))
						_task.returnVal = new ResultType;
				}
				_resultRaw() = val;
				_type = FinishedType.done;
			}
			FinishedHandler call;
			synchronized (this)
				call = _onFinished.move();
			scope (exit)
				_evStart.signaled = true;
			call(_resultRaw);
		}
	}
	else
	{
		void _settleDone()()
		{
			import std.algorithm: move;
			synchronized (this)
				_type = FinishedType.done;
			FinishedHandler call;
			synchronized (this)
				call = _onFinished.move();
			scope (exit)
				_evStart.signaled = true;
			call();
		}
	}
	/// ditto
	void _settleFailed(Exception e)
	{
		import std.algorithm: move;
		synchronized (this)
		{
			_resultException = e;
			_type = FinishedType.failed;
		}
		FailedHandler call;
		synchronized (this)
			call = _onFailed.move();
		scope (exit)
			_evStart.signaled = true;
		call(e);
	}
	/// ditto
	void _settleFatal(Throwable e)
	{
		import std.algorithm: move;
		synchronized (this)
		{
			_resultFatal = e;
			_type = FinishedType.fatal;
		}
		FatalHandler call;
		synchronized (this)
			call = _onFatal.move();
		scope (exit)
			_evStart.signaled = true;
		call(e);
	}
	
	/***************************************************************************
	 * 内側の`Future!ResultType`(`inner`)が確定した際に、その結果(成功/失敗/
	 * 致命的エラー)を`this`へそのまま伝播させる(Promiseの`thenable`展開に相当)。
	 */
	void _adopt(Future!ResultType inner)
	{
		static if (is(ResultType == void))
		{
			inner.addListenerFinished({
				try
					_settleDone();
				catch (Throwable)
				{
					// _settleDone自体が例外を投げることは通常無いはずだが、
					// 万一投げても外側(inner側)の通知処理を巻き込んで
					// 壊さないよう、ここで受け止める。
				}
			});
		}
		else
		{
			inner.addListenerFinished((ref ResultType v){
				try
					_settleDone(v);
				catch (Throwable)
				{
				}
			});
		}
		inner.addListenerFailed((Exception e) nothrow {
			try
				_settleFailed(e);
			catch (Throwable)
			{
			}
		});
		inner.addListenerFatal((Throwable e) nothrow {
			try
				_settleFatal(e);
			catch (Throwable)
			{
			}
		});
	}
	
	/***************************************************************************
	 * `then()`の失敗コールバック(`callbackFailed`)を、対応する派生`Future`
	 * (`future`)に「リカバリ」の意味を持たせて接続する。
	 *
	 * Promiseの`then(onFulfilled, onRejected)`と同じく、`callbackFailed`が
	 * 指定されていて、かつそれが例外を投げずに値(または`Future!Ret2`)を
	 * 返した場合、`future`は*成功*状態に確定する(元の失敗はここで「回収」
	 * され、以降の`.then()`チェーンには伝播しない)。
	 * `callbackFailed`が例外を投げた場合はその新しい例外で、
	 * `callbackFailed`が指定されていない場合は元の例外がそのまま、
	 * `future`は失敗状態になる(Promiseの`.then(onFulfilled)`が
	 * onRejected省略時に reject をそのまま素通しするのと同じ)。
	 *
	 * 致命的エラー(`Throwable`)側はここでは一切扱わない
	 * (`_addListenerFatalWithNewFeature`を参照)。致命的エラーは
	 * 意図的にリカバリ対象から除外している。
	 */
	void _addListenerFailedWithNewFeature(CBRet, FRet)(CBRet delegate(Exception) callbackFailed, Future!FRet future)
	{
		addListenerFailed((Exception e)
		{
			// `future._settleXxx()`自体は原則例外を投げないが、その内部で
			// 呼び出される「(このFutureとは別の)さらに下流に連なる
			// `addListenerFinished`等に登録された任意のコールバック」が
			// 例外を投げる可能性はゼロではない。この関数全体は
			// (nothrow指定の)`_onFailed`から呼ばれるため、万一の場合でも
			// 外へ投げてしまわないよう、`_adopt()`と同様に個々の
			// `_settleXxx()`呼び出しを`try-catch`で受け止める。
			void safeFailed(Exception e2)
			{
				try
					future._settleFailed(e2);
				catch (Throwable)
				{
				}
			}
			void safeFatal(Throwable e2)
			{
				try
					future._settleFatal(e2);
				catch (Throwable)
				{
				}
			}
			if (callbackFailed is null)
			{
				// Promiseの `.then(onFulfilled)` (onRejected省略) と同じく、
				// リカバリ手段が無ければそのまま素通しする。
				safeFailed(e);
				return;
			}
			static if (isFutureInstance!CBRet)
			{
				// callbackFinished同様、callbackFailedも`Future`を返した
				// 場合は自動的にフラット化(chaining)する
				// (Promiseの thenable resolution 相当)。
				CBRet inner;
				try
					inner = callbackFailed(e);
				catch (Exception e2) { safeFailed(e2); return; }
				catch (Throwable e2) { safeFatal(e2); return; }
				if (inner is null)
				{
					safeFailed(new Exception(
						"`then()`の失敗コールバックがnullのFutureを返しました"));
					return;
				}
				try
					future._adopt(inner);
				catch (Throwable)
				{
				}
			}
			else static if (is(CBRet == void))
			{
				try
					callbackFailed(e);
				catch (Exception e2) { safeFailed(e2); return; }
				catch (Throwable e2) { safeFatal(e2); return; }
				try
					future._settleDone();
				catch (Throwable)
				{
				}
			}
			else
			{
				CBRet v;
				try
					v = callbackFailed(e);
				catch (Exception e2) { safeFailed(e2); return; }
				catch (Throwable e2) { safeFatal(e2); return; }
				try
					future._settleDone(v);
				catch (Throwable)
				{
				}
			}
		});
	}
	
	/***************************************************************************
	 * `then()`の致命的エラーコールバック(`callbackFatal`)を、対応する派生
	 * `Future`(`future`)へ接続する。
	 *
	 * `_addListenerFailedWithNewFeature`とは異なり、こちらは意図的に
	 * リカバリ機能を持たない。`callbackFatal`が何をしようと、致命的
	 * エラーは常にそのまま`future`へ伝播し、`future`は必ず`fatal`確定
	 * する。これは、Dの`Error`系(`Throwable`のうち`Exception`でないもの)
	 * が「プログラムが壊れた状態」を示すものであり、ユーザーコードによる
	 * “なかったこと”への揉み消しを許すべきではない、というD言語の
	 * 例外安全の思想に合わせた意図的な設計である(JavaScriptのPromiseには
	 * この区別が無く、`Error`も含めて`.then(_, onRejected)`で自由に
	 * 復帰できてしまうが、`voile.sync.Future`ではあえてそこは真似ない)。
	 */
	void _addListenerFatalWithNewFeature(Ret2)(CallbackFatalType callbackFatal, Future!Ret2 future)
	{
		addListenerFatal((Throwable e)
		{
			if (callbackFatal)
				callbackFatal(e);
			// _execTaskOnFatal ではなく、例外を投げない _settleFatal を使う。
			// このコールバックは(nothrow指定の)_onFatal の emit() 内から
			// 呼ばれるため、ここで万一throwすると Handler.emit() 側の
			// catch-allに握りつぶされるだけでなく、同じ _onFatal に登録された
			// *他の*リスナー(例えば同じFutureに対する2つ目以降の .then())の
			// 呼び出しごと中断させてしまう(結果、そちらの派生Futureが
			// 永久にFinishedType.noneのまま止まり、joinやyieldForceが
			// デッドロックする。Issue #90参照)。
			try
				future._settleFatal(e);
			catch (Throwable)
			{
			}
		});
	}
	
public:
	/***************************************************************************
	 * コンストラクタ
	 */
	this()
	{
		_evStart = new SyncEvent(false);
	}
	/// ditto
	this(SyncEvent evStart)
	{
		_evStart = evStart;
		if (evStart is SyncEvent.init)
		{
			_type = FinishedType.done;
		}
	}
	/// ditto
	this(SyncEvent evStart, TaskPool pool)
	{
		this(evStart);
		_taskPool = pool;
	}
	/// ditto
	static if (!is(Ret == void))
	{
		this(ResultType val, SyncEvent evStart = null)
		{
			import std.algorithm: move;
			static assert(isPointer!TaskType);
			// Taskのインスタンスを無理やり生成することでreturnValのスペースを確保する
			_task = new PointerTarget!TaskType;
			static if (is(typeof(_task.returnVal) == ResultType*))
				_task.returnVal = new ResultType;
			_resultRaw() = val.move();
			_type = FinishedType.done;
			if (evStart !is null)
				evStart.signaled = true;
		}
	}
	/// ditto
	this(Exception e, SyncEvent evStart = null)
	{
		_evStart = new SyncEvent(true);
		_resultException = e;
		_type = FinishedType.failed;
		if (evStart !is null)
			evStart.signaled = true;
	}
	
	/***************************************************************************
	 * 終了したら呼ばれる
	 */
	auto perform(alias func, Args...)(TaskPool pool, Args args)
		if (is(typeof(func(args)) == ResultType))
	{
		_makeTask!func(this, args);
		_submit(pool);
		_evStart.signaled = true;
		return this;
	}
	/// ditto
	auto perform(alias func, Args...)(Args args)
		if (is(typeof(func(args)) == ResultType))
	{
		_makeTask!func(this, args);
		if (_taskPool)
		{
			_submit(_taskPool);
		}
		else
		{
			_task.executeInNewThread();
		}
		_evStart.signaled = true;
		return this;
	}
	/// ditto
	auto perform(F, Args...)(TaskPool pool, F dg, Args args)
		if (is(typeof(dg(args)) == ResultType))
	{
		_makeTask!_dgRun(this, dg, args);
		_submit(pool);
		_evStart.signaled = true;
		return this;
	}
	/// ditto
	auto perform(F, Args...)(F dg, Args args)
		if (is(typeof(dg(args)) == ResultType))
	{
		_makeTask!_dgRun(this, dg, args);
		if (_taskPool)
		{
			_submit(_taskPool);
		}
		else
		{
			_task.executeInNewThread();
		}
		_evStart.signaled = true;
		return this;
	}
	
	/***************************************************************************
	 * チェーン
	 */
	auto then(Ret2)(TaskPool pool,
		Ret2 delegate(ResultType) callbackFinished,
		Ret2 delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (!is(Ret == void) && is(typeof(callbackFinished(_resultRaw))))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished((ref ResultType result) {
				Ret2 inner;
				try
					inner = callbackFinished(result);
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished((ref ResultType result) { ret.perform(pool, callbackFinished, result); });
		}
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(Ret2)(
		Ret2 delegate(ResultType) callbackFinished,
		Ret2 delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (!is(Ret == void) && is(typeof(callbackFinished(_resultRaw))))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished((ref ResultType result) {
				Ret2 inner;
				try
					inner = callbackFinished(result);
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished((ref ResultType result){ ret.perform(callbackFinished, result); });
		}
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception, Ret2 = ReturnType!func)(TaskPool pool,
		Ret2 delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (!is(Ret == void) && is(typeof(func(_resultRaw))) && is(Ex == Exception)
		&& is(Ret2 == typeof(func(_resultRaw))))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished((ref ResultType result) {
				Ret2 inner;
				try
					inner = func(result);
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished((ref ResultType result) { ret.perform!func(pool, result); });
		}
		_addListenerFailedWithNewFeature!Ret2(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception, Ret2 = ReturnType!func)(
		Ret2 delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (!is(Ret == void) && is(typeof(func(_resultRaw))) && is(Ex == Exception)
		&& is(Ret2 == typeof(func(_resultRaw))))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished((ref ResultType result) {
				Ret2 inner;
				try
					inner = func(result);
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished((ref ResultType result) { ret.perform!func(result); });
		}
		_addListenerFailedWithNewFeature!Ret2(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(Ret2)(TaskPool pool,
		Ret2 delegate() callbackFinished,
		Ret2 delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (is(Ret == void) && is(typeof(callbackFinished())))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished(() {
				Ret2 inner;
				try
					inner = callbackFinished();
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished(() { ret.perform(pool, callbackFinished); });
		}
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(Ret2)(
		Ret2 delegate() callbackFinished,
		Ret2 delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (is(Ret == void) && is(typeof(callbackFinished())))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished(() {
				Ret2 inner;
				try
					inner = callbackFinished();
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished((){ ret.perform(callbackFinished); });
		}
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception, Ret2 = ReturnType!func)(TaskPool pool,
		Ret2 delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (is(Ret == void) && is(typeof(func())) && is(Ex == Exception)
		&& is(Ret2 == typeof(func())))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished(() {
				Ret2 inner;
				try
					inner = func();
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished( () { ret.perform!func(pool); });
		}
		_addListenerFailedWithNewFeature!Ret2(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception, Ret2 = ReturnType!func)(
		Ret2 delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
	if (is(Ret == void) && is(typeof(func())) && is(Ex == Exception)
		&& is(Ret2 == typeof(func())))
	{
		static if (isFutureInstance!Ret2)
		{
			alias InnerRet = FutureResultType!Ret2;
			auto ret = new Future!InnerRet;
			addListenerFinished(() {
				Ret2 inner;
				try
					inner = func();
				catch (Exception e) { ret._settleFailed(e); return; }
				catch (Throwable e) { ret._settleFatal(e); return; }
				if (inner is null)
				{
					ret._settleFailed(new Exception("`then()`のコールバックがnullのFutureを返しました"));
					return;
				}
				ret._adopt(inner);
			});
		}
		else
		{
			auto ret = new Future!Ret2;
			addListenerFinished( () { ret.perform!func(); } );
		}
		_addListenerFailedWithNewFeature!Ret2(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	
	/***************************************************************************
	 * 失敗(`Exception`)からの復帰用メソッド
	 * 
	 * `then()`の`callbackFailed`と同様にリカバリ可能だが、`Ex`テンプレート
	 * 引数に一致する(=`cast(Ex)`が成功する)`Exception`が発生した場合にのみ
	 * `callbackFailed`を呼ぶ点が異なる。一致しない`Exception`はそのまま
	 * 素通しする。元の`Future`が成功していた場合はその値をそのまま透過する。
	 * 
	 * 名前を(Promiseに合わせた)`catch`ではなく`except`としているのは、
	 * 1. `catch`はDの予約語であり、そのままメソッド名にはできないこと。
	 * 2. Promiseの`.catch()`は(JSの`catch`同様)投げられたものは何でも
	 *    拾うという語感を持つが、本メソッドは致命的エラー(`Throwable`の
	 *    うち`Exception`でないもの、Dの`Error`系)までは拾わない
	 *    (=`Exception`派生に限定する)ため、`catch`と呼ぶと誤解を招く。
	 * という2つの理由による。
	 * 
	 * Params:
	 *     callbackFailed = `Ex`に一致する例外が発生したときに呼ばれる
	 *         コールバック。`ResultType`(または`Future!ResultType`、
	 *         この場合は自動的にフラット化される)を返す。
	 */
	static if (!is(Ret == void))
	{
		auto except(Ex : Exception = Exception, RetOrFuture)(RetOrFuture delegate(Ex) callbackFailed)
		if (is(RetOrFuture == ResultType)
			|| (isFutureInstance!RetOrFuture && is(FutureResultType!RetOrFuture == ResultType)))
		{
			auto ret = new Future!ResultType;
			addListenerFinished((ref ResultType v) { ret._settleDone(v); });
			addListenerFailed((Exception e)
			{
				void safeFailed(Exception e2)
				{
					try
						ret._settleFailed(e2);
					catch (Throwable)
					{
					}
				}
				void safeFatal(Throwable e2)
				{
					try
						ret._settleFatal(e2);
					catch (Throwable)
					{
					}
				}
				auto ex = cast(Ex)e;
				if (ex is null)
				{
					safeFailed(e);
					return;
				}
				static if (isFutureInstance!RetOrFuture)
				{
					RetOrFuture inner;
					try
						inner = callbackFailed(ex);
					catch (Exception e2) { safeFailed(e2); return; }
					catch (Throwable e2) { safeFatal(e2); return; }
					if (inner is null)
					{
						safeFailed(new Exception("`except()`のコールバックがnullのFutureを返しました"));
						return;
					}
					try
						ret._adopt(inner);
					catch (Throwable)
					{
					}
				}
				else
				{
					ResultType v;
					try
						v = callbackFailed(ex);
					catch (Exception e2) { safeFailed(e2); return; }
					catch (Throwable e2) { safeFatal(e2); return; }
					try
						ret._settleDone(v);
					catch (Throwable)
					{
					}
				}
			});
			addListenerFatal((Throwable e)
			{
				try
					ret._settleFatal(e);
				catch (Throwable)
				{
				}
			});
			return ret;
		}
	}
	else
	{
		/// ditto
		auto except(Ex : Exception = Exception, RetOrFuture)(RetOrFuture delegate(Ex) callbackFailed)
		if (is(RetOrFuture == void)
			|| (isFutureInstance!RetOrFuture && is(FutureResultType!RetOrFuture == void)))
		{
			auto ret = new Future!void;
			addListenerFinished(() { ret._settleDone(); });
			addListenerFailed((Exception e)
			{
				void safeFailed(Exception e2)
				{
					try
						ret._settleFailed(e2);
					catch (Throwable)
					{
					}
				}
				void safeFatal(Throwable e2)
				{
					try
						ret._settleFatal(e2);
					catch (Throwable)
					{
					}
				}
				auto ex = cast(Ex)e;
				if (ex is null)
				{
					safeFailed(e);
					return;
				}
				static if (isFutureInstance!RetOrFuture)
				{
					RetOrFuture inner;
					try
						inner = callbackFailed(ex);
					catch (Exception e2) { safeFailed(e2); return; }
					catch (Throwable e2) { safeFatal(e2); return; }
					if (inner is null)
					{
						safeFailed(new Exception("`except()`のコールバックがnullのFutureを返しました"));
						return;
					}
					try
						ret._adopt(inner);
					catch (Throwable)
					{
					}
				}
				else
				{
					try
						callbackFailed(ex);
					catch (Exception e2) { safeFailed(e2); return; }
					catch (Throwable e2) { safeFatal(e2); return; }
					try
						ret._settleDone();
					catch (Throwable)
					{
					}
				}
			});
			addListenerFatal((Throwable e)
			{
				try
					ret._settleFatal(e);
				catch (Throwable)
				{
				}
			});
			return ret;
		}
	}
	
	/***************************************************************************
	 * 成功/失敗/致命的エラーのいずれであっても必ず実行される後処理を登録する。
	 * (JavaScriptの`Promise.prototype.finally()`に相当。Dの予約語`finally`を
	 * メソッド名に使えないため`always`としている。)
	 * 
	 * `callback`の戻り値は結果に影響を与えない(=成功/失敗/致命的エラーの
	 * いずれであっても、その結果はそのまま透過する)。ただし`callback`自身が
	 * 例外(または致命的エラー)を投げた場合は、Promiseの`finally()`と同様に、
	 * その新しい例外/エラーで返り値の`Future`が確定する(元の結果は上書きされる)。
	 */
	auto always(void delegate() callback)
	{
		auto ret = new Future!Ret;
		static if (is(Ret == void))
		{
			addListenerFinished(() {
				try
					callback();
				catch (Exception e2) { ret._settleFailed(e2); return; }
				catch (Throwable e2) { ret._settleFatal(e2); return; }
				ret._settleDone();
			});
		}
		else
		{
			addListenerFinished((ref ResultType v) {
				try
					callback();
				catch (Exception e2) { ret._settleFailed(e2); return; }
				catch (Throwable e2) { ret._settleFatal(e2); return; }
				ret._settleDone(v);
			});
		}
		addListenerFailed((Exception e)
		{
			void safeFailed(Exception e2)
			{
				try
					ret._settleFailed(e2);
				catch (Throwable)
				{
				}
			}
			void safeFatal(Throwable e2)
			{
				try
					ret._settleFatal(e2);
				catch (Throwable)
				{
				}
			}
			try
				callback();
			catch (Exception e2) { safeFailed(e2); return; }
			catch (Throwable e2) { safeFatal(e2); return; }
			safeFailed(e);
		});
		addListenerFatal((Throwable e)
		{
			void safeFailed(Exception e2)
			{
				try
					ret._settleFailed(e2);
				catch (Throwable)
				{
				}
			}
			void safeFatal(Throwable e2)
			{
				try
					ret._settleFatal(e2);
				catch (Throwable)
				{
				}
			}
			try
				callback();
			catch (Exception e2) { safeFailed(e2); return; }
			catch (Throwable e2) { safeFatal(e2); return; }
			safeFatal(e);
		});
		return ret;
	}
	
	/***************************************************************************
	 * 終了したら呼ばれるコールバックをハンドラに登録
	 * 
	 * 指定されたコールバックは並列処理が正常終了したときにのみ呼び出される。
	 * 並列処理がまだ終了していない場合には並列処理を行っていたスレッドでコールバックが呼び出される。
	 * すでに並列処理が終了していた場合、`TaskPool`が設定されており、かつそこに
	 * ワーカースレッドが存在するなら、Promiseの`.then()`同様そのプールへ
	 * ディスパッチして非同期的にコールバックを呼び出す。
	 * `TaskPool`が設定されていない(または`size`が0の)場合は、現在のスレッドで
	 * 即座に(同期的に)コールバックが呼び出される。
	 * コールバック内で例外が発生した場合には、Failed, Fatalのハンドラが呼び出され、
	 * Futureの状態も各々の状態へと変化する。
	 * 
	 * Params:
	 *     dg = 設定するコールバックを指定する。nullを指定したらハンドラに登録されたすべてのコールバックをクリアする。
	 * Returns:
	 *     登録したハンドラのIDを返す。登録されなかった場合はFinishedHandler.HandlerProcId.initが返る
	 */
	FinishedHandler.HandlerProcId addListenerFinished(CallbackType dg)
	{
		import std.algorithm: move;
		synchronized (this)
		{
			if (dg is null)
			{
				_onFinished.clear();
				return FinishedHandler.HandlerProcId.init;
			}
			else
			{
				if (_type == FinishedType.none)
				{
					return _onFinished.connect(dg);
				}
				else if (_type != FinishedType.done)
				{
					return FinishedHandler.HandlerProcId.init;
				}
				else
				{
					// 何もしない=関数の最後でdgの呼び出しを行う
				}
			}
		}
		void callNow()
		{
			try
			{
				static if (is(Ret == void))
				{
					dg();
				}
				else
				{
					dg(_resultRaw);
				}
			}
			catch (Exception e)
			{
				FailedHandler call;
				synchronized (this)
				{
					call = _onFailed.move();
					_type = FinishedType.failed;
				}
				call(e);
			}
			catch (Throwable e)
			{
				FatalHandler call;
				synchronized (this)
				{
					call = _onFatal.move();
					_type = FinishedType.fatal;
				}
				call(e);
			}
		}
		if (_taskPool !is null && _taskPool.size > 0)
			_taskPool.put(task(&callNow));
		else
			callNow();
		return FinishedHandler.HandlerProcId.init;
	}
	
	/***************************************************************************
	 * 例外が発生したら呼ばれる
	 * 
	 * `addListenerFinished`同様、すでに`failed`確定済みの状態へ後から登録した
	 * 場合は、`TaskPool`が設定されており(かつワーカースレッドが存在する)場合に
	 * 限り非同期にディスパッチし、それ以外は同期的に呼び出す。
	 * 
	 * Params:
	 *     dg = 設定するコールバックを指定する。nullを指定したらすべてのコールバックをクリアする。
	 * Returns:
	 *     登録したハンドラのIDを返す。登録されなかった場合はFailedHandler.HandlerProcId.initが返る
	 */
	FailedHandler.HandlerProcId addListenerFailed(CallbackFailedType dg)
	{
		synchronized (this)
		{
			if (dg is null)
			{
				_onFailed.clear();
				return FailedHandler.HandlerProcId.init;
			}
			else
			{
				if (_type == FinishedType.none)
				{
					return _onFailed.connect(dg);
				}
				else if (_type != FinishedType.failed)
				{
					return FailedHandler.HandlerProcId.init;
				}
				else
				{
					// 何もしない=関数の最後でdgの呼び出しを行う
				}
			}
		}
		void callNow()
		{
			try
				dg(_resultException);
			catch (Throwable)
			{
				// dg は nothrow のはずだが、内部実装(_addListenerFailedWithNewFeatureの
				// ラッパー等)がcast経由でnothrow指定を回避し例外を送出することがあるため、
				// (addListenerFinishedの「既に完了している場合の即時呼び出し」パスと同様に)
				// プロセス全体をクラッシュさせないための保険としてここで受け止める。
			}
		}
		if (_taskPool !is null && _taskPool.size > 0)
			_taskPool.put(task(&callNow));
		else
			callNow();
		return FailedHandler.HandlerProcId.init;
	}
	
	
	/***************************************************************************
	 * 致命的エラーが発生したら呼ばれる
	 * 
	 * Params:
	 *     dg = 設定するコールバックを指定する。nullを指定したらすべてのコールバックをクリアする。
	 * Returns:
	 *     登録したハンドラのIDを返す。登録されなかった場合はFatalHandler.HandlerProcId.initが返る
	 * Note:
	 *     `addListenerFinished`/`addListenerFailed`とは異なり、`TaskPool`が
	 *     設定されていても非同期ディスパッチは行わず、常に呼び出し元のスレッドで
	 *     同期的にコールバックを呼び出す。
	 *     致命的エラー(`Throwable`)は「プログラムが壊れた状態」を示すため、
	 *     `TaskPool`のワーカースレッドへ委譲して伝播タイミングを不確定にしてしまうと、
	 *     誰にも観測されないままワーカースレッドの中だけで“握りつぶされたように”
	 *     放置されかねない(スレッド自体は`std.parallelism`の仕組みにより
	 *     死なずに次のタスクを処理し続けてしまうため、プロセス全体は落ちず、
	 *     しかし内部状態は壊れたまま、という最も避けたい不安定な状態になる)。
	 *     これを避けるため、致命的エラーの伝播だけは常に同期的(=検出したその場)
	 *     で行う。
	 */
	FatalHandler.HandlerProcId addListenerFatal(CallbackFatalType dg)
	{
		synchronized (this)
		{
			if (dg is null)
			{
				_onFatal.clear();
				return FatalHandler.HandlerProcId.init;
			}
			else
			{
				if (_type == FinishedType.none)
				{
					return _onFatal.connect(dg);
				}
				else if (_type != FinishedType.fatal)
				{
					return FatalHandler.HandlerProcId.init;
				}
				else
				{
					/* 何もしない=関数の最後でdgの呼び出しを行う */
				}
			}
		}
		try
			dg(_resultFatal);
		catch (Throwable)
		{
			// addListenerFailed と同様の保険。
		}
		return FatalHandler.HandlerProcId.init;
	}
	
	/***************************************************************************
	 * 登録していたハンドラを削除する
	 */
	void removeListenerFinished(FinishedHandler.HandlerProcId id)
	{
		synchronized (this)
		{
			_onFinished.disconnect(id);
		}
	}
	/// ditto
	void removeListenerFailed(FailedHandler.HandlerProcId id)
	{
		synchronized (this)
		{
			_onFailed.disconnect(id);
		}
	}
	/// ditto
	void removeListenerFatal(FatalHandler.HandlerProcId id)
	{
		synchronized (this)
		{
			_onFatal.disconnect(id);
		}
	}
	
	/***************************************************************************
	 * 終了しているか(例外発生含む)
	 */
	bool done() const
	{
		return !_evStart || (_type != FinishedType.none);
	}
	
	/***************************************************************************
	 * 終了するまで待機する
	 */
	void join(bool rethrow = false) const
	{
		if (!_evStart)
			return;
		_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			try
				(cast(TaskType)_task).yieldForce();
			catch (Throwable e)
			{
				// `rethrow`引数を無視して例外を投げてしまわないよう、
				// ここで一旦受け止めたうえで`rethrow`の指示に従う。
				// (このcase節に来るのは`_type`がまだ`none`のまま
				// `_task`自身の完了待ちに委ねている場合であり、
				// `_type`が`failed`/`fatal`へ確定済みの場合と挙動を
				// 一致させる必要がある)
				if (rethrow)
					throw e;
			}
			break;
		case FinishedType.done:
			break;
		case FinishedType.failed:
			if (rethrow)
				throw cast()_resultException;
			break;
		case FinishedType.fatal:
			if (rethrow)
				throw cast()_resultFatal;
			break;
		}
	}
	
	
	/***************************************************************************
	 * 結果を受け取る
	 */
	ref auto yieldForce() inout
	{
		if (!_evStart)
			return _resultRaw();
		if (_type == FinishedType.none)
			_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).yieldForce();
			return _resultRaw();
		case FinishedType.done:
			return _resultRaw();
		case FinishedType.failed:
			throw cast()_resultException;
		case FinishedType.fatal:
			throw cast()_resultFatal;
		}
	}
	
	/// ditto
	ref auto workForce() inout
	{
		if (!_evStart)
			return _resultRaw();
		if (_type == FinishedType.none)
			_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).workForce();
			return _resultRaw();
		case FinishedType.done:
			return _resultRaw();
		case FinishedType.failed:
			throw cast()_resultException;
		case FinishedType.fatal:
			throw cast()_resultFatal;
		}
	}
	
	/// ditto
	ref auto spinForce() inout
	{
		if (!_evStart)
			return _resultRaw();
		if (_type == FinishedType.none)
			_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).spinForce();
			return _resultRaw();
		case FinishedType.done:
			return _resultRaw();
		case FinishedType.failed:
			throw cast()_resultException;
		case FinishedType.fatal:
			throw cast()_resultFatal;
		}
	}
	
	static if (!is(Ret == void))
	{
		/// ditto
		ref inout(ResultType) result() inout @property
		{
			import std.exception;
			enforce((cast(Future)this)._type == FinishedType.done);
			return _resultRaw();
		}
	}
	
}

/// ditto
@system unittest
{
	auto future = new Future!int;
	future.perform(delegate (int a) => a + 10, 10);
	assert(future.yieldForce() == 20);
	future.perform(taskPool, delegate (int a) => a + 20, 10);
	assert(future.yieldForce() == 30);
	static int foo(int a) { return a + 30; }
	future.perform!foo(10);
	assert(future.yieldForce() == 40);
	future.perform!foo(taskPool, 10);
	assert(future.yieldForce() == 40);
	
	auto future2 = future.perform(delegate (int a) => a + 10, 10)
		.then((int a) => cast(ulong)(a + 20))
		.then(a => a + 20)
		.then!((ulong a) => a + 60)()
		.then(taskPool, a => cast(int)(a + 20))
		.then!((ref int a) => a + 60)(taskPool);
	auto future3 = future2
		.then((int a){ assert(a == 200); })
		.then(taskPool, (){  })
		.then((){  })
		.then!((){  })
		.then!((){  })(taskPool);
	assert(future2.yieldForce() == 200);
	future3.join();
	
}

/// ditto
@system unittest
{
	// `callbackFailed`はリカバリ可能のため、
	// (提供されたコールバックが例外を投げずに正常終了すると)chainは
	// *成功*状態に復帰する。このテストは「failedのまま伝播すること」を
	// 検証する意図なので、明示的に再送出して元の挙動を保つ。
	Exception lastEx;
	auto feature = async({
		throw new Exception("Ex1");
	}).then({
		assert(0);
	}, (Exception e){
		lastEx = e;
		throw e;
	});
	try
	{
		feature.join(true);
	}
	catch (Exception e)
	{
		assert(lastEx.msg == "Ex1");
		assert(lastEx is e);
	}
}

/// ditto
@system unittest
{
	import std.exception;
	// Note: 上記と同様の理由で、callbackFailedから明示的に再送出する。
	Exception e1, e2;
	auto future1 = async({
		throw new Exception("Ex1");
	});
	auto future2 = future1.then({
		assert(0);
	}, (Exception e)
	{
		// future1の例外処理
		e1 = e;
		throw e;
	});
	
	// future1でEx1が投げられている
	e2 = future1.join(true).collectException();
	assert(e2.msg == "Ex1");
	// future2もEx1が投げられたことになっている
	e2 = future2.join(true).collectException();
	assert(e2.msg == "Ex1");
	assert(e1 is e2);
}

/// ditto
@system unittest
{
	import std.exception;
	Exception e1, e2;
	auto future1 = async(
	{
		// future1の処理
	});
	auto future2 = future1.then(
	{
		// feature1の後続処理
		throw new Exception("Ex1");
	}, (Exception e)
	{
		// future1の例外処理
		e1 = e;
	});
	auto future3 = future2.then(
	{
		// feature2の後続処理
		throw new Exception("Ex2");
	}, (Exception e)
	{
		// future2の例外処理
		e2 = e;
	});
	
	// future1では例外が投げられない
	auto e3 = future1.join(true).collectException();
	assert(e1 is null);
	assert(e3 is null);
	// future2ではEx1例外が投げられる
	auto e4 = future2.join(true).collectException();
	assert(e2 !is null);
	assert(e2 is e4);
	assert(e2.msg == "Ex1");
	// (Ex2は投げられない)
}

// ワーカースレッド数0のTaskPoolでもデッドロックしないことのテスト
@system unittest
{
	import std.parallelism: TaskPool;
	// ワーカースレッドを1つも持たないプールへ明示的に投げる。
	// (通常totalCPUs-1個のワーカーが自動的に立つが、ここでは
	// totalCPUsの値に依存せず確実に「誰も拾わない」状況を再現するため
	// 明示的に0ワーカーのプールを構築する)
	auto pool0 = new TaskPool(0);
	scope (exit)
		pool0.finish();
	assert(pool0.size == 0);
	auto future = new Future!int;
	future.perform(pool0, delegate (int a) => a + 20, 10);
	// 修正前はここで永久にハングした(_evStartがタスク実行開始時に
	// シグナルされる一方、実行開始はワーカーがいないため永久に起こらず、
	// かつ自スレッドでの代行実行(Task.yieldForce())へも到達できなかったため)。
	assert(future.yieldForce() == 30);

	// .then() でチェーンした先の future もデッドロックしないことを確認する
	auto future2 = new Future!int;
	future2.perform(pool0, delegate (int a) => a, 10);
	auto future3 = future2
		.then(pool0, (int a) => a + 1)
		.then(pool0, (int a) => a + 1);
	assert(future3.yieldForce() == 12);
}

/* *****************************************************************************
 * Future の Promise 的挙動に関する回帰テスト
 * 
 * `known-issues-voile.md` Issue 12 参照。`.then()` を既に確定済み(failed/fatal)の
 * Future に対して呼び出すと、addListenerFailed()/addListenerFatal() の
 * 「即時呼び出し」経路がtry/catchで保護されていなかったため、プロセス全体が
 * クラッシュしていた。addListenerFinished()には元々このtry/catchが存在して
 * おり、非対称な実装漏れだった。
 */
@system unittest
{
	import std.exception: collectException;
	// 既に failed 確定済みの Future に .then() を呼んでもクラッシュしない
	// (JS Promiseの `.then()` は決して同期的に例外を投げない、という契約に相当)
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Exception("already failed"); return a; }, 10);
	future.join(false);
	bool onRejectedCalled;
	int delegate(Exception) onRejected = (Exception e) {
		onRejectedCalled = true;
		throw e;
	};
	auto d = future.then((int a) => a + 1, onRejected);
	assert(onRejectedCalled);
	bool dFailed;
	try
		d.yieldForce();
	catch (Exception e)
		dFailed = true;
	assert(dFailed);
}

// 同じFutureに複数の.then()を接続しても、両方とも独立して正しく通知される
@system unittest
{
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Exception("original boom"); return a; }, 10);
	bool failed1Called, failed2Called;
	int delegate(Exception) onRejected1 = (Exception e) { failed1Called = true; throw e; };
	int delegate(Exception) onRejected2 = (Exception e) { failed2Called = true; throw e; };
	auto d1 = future.then((int a) => a + 1, onRejected1);
	auto d2 = future.then((int a) => a + 2, onRejected2);
	d1.join(false);
	d2.join(false);
	assert(failed1Called);
	assert(failed2Called);
}

/* *****************************************************************************
 * `then()`の失敗コールバックによるリカバリ(Promiseの
 * `then(onFulfilled, onRejected)`が`onRejected`の戻り値で成功状態に
 * 復帰できるのと同じ挙動)に関する機能テスト。
 */
@system unittest
{
	// onRejectedが値を返せば、chainは*成功*状態に復帰する
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto recovered = future.then((int a) => a + 1, (Exception e) => 999);
	assert(recovered.yieldForce() == 999);
}
// onRejected未指定の場合はPromise同様そのまま素通しする
@system unittest
{
	import std.exception: assertThrown;
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto passthrough = future.then((int a) => a + 1);
	assertThrown!Exception(passthrough.yieldForce());
}
// onRejectedが投げた場合は新しい例外でfailedになる
@system unittest
{
	import std.exception: collectException;
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	// `{ throw ...; }`という「returnを持たないブロック」のラムダリテラルは、
	// (このように単独の式として渡すと)戻り値の型が`void`と推論されてしまい、
	// `Ret2`(=int)と一致しなくなるため、明示的に型注釈する。
	int delegate(Exception) onRejected = (Exception e) {
		throw new Exception("rewrapped: " ~ e.msg);
	};
	auto rethrown = future.then((int a) => a + 1, onRejected);
	auto e = collectException!Exception(rethrown.yieldForce());
	assert(e !is null && e.msg == "rewrapped: boom");
}
// onRejectedがFutureを返した場合もフラット化(chaining)される。
// この場合はcallbackFinished側も同じ`Ret2`(=Future!int)を返す必要がある
@system unittest
{
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto fallback = new Future!int(123);
	auto recovered = future.then((int a) => new Future!int(a + 1), (Exception e) => fallback);
	assert(recovered.yieldForce() == 123);
}
// Ret==voidの`then()`でも同様にリカバリできる
@system unittest
{
	auto future = new Future!void;
	future.perform(delegate () { throw new Exception("boom"); });
	bool recoveredRan;
	auto recovered = future.then(() {}, (Exception e) { recoveredRan = true; });
	recovered.yieldForce();
	assert(recoveredRan);
}
// 致命的エラー(Throwable)は`then()`のcallbackFailedでは一切拾えず、callbackFatalが何をしようと常に伝播する。
@system unittest
{
	import std.exception: collectException;
	auto future = new Future!int;
	future.perform(delegate (int a) { throw new Error("fatal boom"); return a; }, 10);
	bool onRejectedCalled, onFatalCalled;
	auto d = future.then((int a) => a + 1,
		(Exception e) { onRejectedCalled = true; return -1; },
		(Throwable e) { onFatalCalled = true; });
	auto err = collectException!Error(d.yieldForce());
	assert(!onRejectedCalled);
	assert(onFatalCalled);
	assert(err !is null && err.msg == "fatal boom");
}

/* *****************************************************************************
 * `except()`(Pythonの`except SpecificError:`に相当する、型フィルタ付きの
 * 失敗リカバリ専用メソッド)に関する機能テスト。
 */
@system unittest
{
	import std.exception: assertThrown;
	static class MyException : Exception
	{
		this(string msg) { super(msg); }
	}
	// 型が一致すればリカバリする
	auto future1 = new Future!int;
	future1.perform(delegate (int a) { throw new MyException("specific"); return a; }, 10);
	auto recovered1 = future1.except!MyException((MyException e) => 42);
	assert(recovered1.yieldForce() == 42);
	
	// 型が一致しなければ素通しする
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("generic"); return a; }, 10);
	auto recovered2 = future2.except!MyException((MyException e) => 42);
	assertThrown!Exception(recovered2.yieldForce());
	
	// 元のFutureが成功していればそのまま値が透過する
	auto future3 = new Future!int(10);
	auto recovered3 = future3.except!MyException((MyException e) => 42);
	assert(recovered3.yieldForce() == 10);
	
	// 型を指定しなければExceptionすべてを拾う(デフォルト)
	auto future4 = new Future!int;
	future4.perform(delegate (int a) { throw new Exception("anything"); return a; }, 10);
	auto recovered4 = future4.except((Exception e) => 100);
	assert(recovered4.yieldForce() == 100);
	
	// 致命的エラー(Throwable)はexcept()でも一切拾わない
	auto future5 = new Future!int;
	future5.perform(delegate (int a) { throw new Error("fatal"); return a; }, 10);
	auto recovered5 = future5.except((Exception e) => 100);
	assertThrown!Error(recovered5.yieldForce());
}
// ditto (Ret==voidでも動作する)
@system unittest
{
	auto future = new Future!void;
	future.perform(delegate () { throw new Exception("boom"); });
	bool recoveredRan;
	future.except((Exception e) { recoveredRan = true; }).yieldForce();
	assert(recoveredRan);
}

/* *****************************************************************************
 * `always()`(Promiseの`.finally()`相当。成功/失敗/致命的
 * エラーいずれでも必ず実行され、結果自体は変化させない)に関する機能テスト。
 */
@system unittest
{
	import std.exception: collectException, assertThrown;
	// 成功時: alwaysのコールバックが呼ばれ、値はそのまま透過する
	auto future1 = new Future!int(10);
	int calledCount;
	auto d1 = future1.always(() { calledCount++; });
	assert(d1.yieldForce() == 10);
	assert(calledCount == 1);
	
	// 失敗時: alwaysのコールバックが呼ばれ、失敗もそのまま透過する
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	int calledCount2;
	auto d2 = future2.always(() { calledCount2++; });
	assertThrown!Exception(d2.yieldForce());
	assert(calledCount2 == 1);
	
	// 致命的エラー時: alwaysのコールバックが呼ばれ、致命的エラーもそのまま透過する
	auto future3 = new Future!int;
	future3.perform(delegate (int a) { throw new Error("fatal"); return a; }, 10);
	int calledCount3;
	auto d3 = future3.always(() { calledCount3++; });
	assertThrown!Error(d3.yieldForce());
	assert(calledCount3 == 1);
	
	// alwaysのコールバック自体が例外を投げた場合、その新しい例外で上書きされる
	auto future4 = new Future!int(10);
	auto d4 = future4.always(() { throw new Exception("finally boom"); });
	auto e4 = collectException!Exception(d4.yieldForce());
	assert(e4 !is null && e4.msg == "finally boom");
	
	// alwaysはalwaysのエイリアス
	auto future5 = new Future!int(10);
	int calledCount5;
	auto d5 = future5.always(() { calledCount5++; });
	assert(d5.yieldForce() == 10);
	assert(calledCount5 == 1);
}
// ditto (Ret==voidでも動作する)
@system unittest
{
	auto future = new Future!void;
	future.perform(delegate () {});
	int calledCount;
	auto d = future.always(() { calledCount++; });
	d.yieldForce();
	assert(calledCount == 1);
}

/* *****************************************************************************
 * `TaskPool`が設定されている場合のみ、既に確定済みのFutureへ後から
 * 登録したコールバックの呼び出しを非同期(そのプールへディスパッチ)にする。
 * 設定されていない場合は従来通り同期的に呼び出す。
 */
@system unittest
{
	import core.thread: Thread, ThreadID;
	// プール未設定の場合: 同期的に(呼び出し元と同じスレッドで)呼ばれる
	auto future = new Future!int(10);
	auto mainThreadId = Thread.getThis().id;
	ThreadID calledThreadId;
	bool called;
	future.addListenerFinished((ref int v) {
		calledThreadId = Thread.getThis().id;
		called = true;
	});
	assert(called);
	assert(calledThreadId == mainThreadId);
}
// ditto (プール設定時: 別スレッド(プールのワーカー)へディスパッチされる)
@system unittest
{
	import core.thread: Thread, ThreadID;
	import core.sync.semaphore: Semaphore;
	auto pool = new TaskPool(1);
	scope (exit)
	{
		pool.finish(true);
	}
	auto future = new Future!int(10, null);
	future._taskPool = pool;
	auto mainThreadId = Thread.getThis().id;
	auto sem = new Semaphore;
	ThreadID calledThreadId;
	future.addListenerFinished((ref int v) {
		calledThreadId = Thread.getThis().id;
		sem.notify();
	});
	sem.wait();
	assert(calledThreadId != mainThreadId);
}

/* *****************************************************************************
 * `this(Exception e, SyncEvent evStart = null)` (`Promise.reject(reason)`
 * 相当、最初からfailed確定済みのFutureを作るコンストラクタ)に関する機能テスト。
 */
@system unittest
{
	import std.exception: collectException, assertThrown;
	auto future = new Future!int(new Exception("born failed"));
	assert(future.done());
	auto e = collectException!Exception(future.yieldForce());
	assert(e !is null && e.msg == "born failed");
	
	// join(rethrow=true)でも正しく再送出される
	auto future2 = new Future!int(new Exception("born failed 2"));
	auto e2 = collectException!Exception(future2.join(true));
	assert(e2 !is null && e2.msg == "born failed 2");
	
	// join(rethrow=false)は例外を投げない
	auto future3 = new Future!int(new Exception("born failed 3"));
	future3.join(false);
	
	// Ret==voidでも使える
	auto future4 = new Future!void(new Exception("void failed"));
	assertThrown!Exception(future4.yieldForce());
	
	// .then()と組み合わせても正しく失敗として扱われる
	auto future5 = new Future!int(new Exception("born failed 5"));
	auto recovered5 = future5.then((int a) => a + 1, (Exception e) => 777);
	assert(recovered5.yieldForce() == 777);
}

/* *****************************************************************************
 * Future の `.then()` が Future を返した場合の自動フラット化(chaining)に
 * 関するテスト(JavaScriptのPromiseにおける thenable resolution に相当)。
 * 
 * 修正前は `then((int a) => someFuture)` の戻り値が `Future!(Future!int)` と
 * 二重にネストしてしまい、Promiseのように自動的に内側のFutureの結果へ
 * 展開されることはなかった。
 */
@system unittest
{
	// 1. 内側のFutureが成功する場合、外側もその値で成功する
	auto future1 = new Future!int;
	future1.perform(delegate (int a) => a + 10, 10);
	auto inner1 = new Future!int;
	inner1.perform(delegate (int a) => a * 100, 5);
	auto chained1 = future1.then((int a) => inner1);
	static assert(is(typeof(chained1) == Future!int));
	assert(chained1.yieldForce() == 500);
}
// ditto (内側のFutureが失敗する場合、外側もfailedになる)
@system unittest
{
	auto future2 = new Future!int;
	future2.perform(delegate (int a) => a + 10, 10);
	auto inner2 = new Future!int;
	inner2.perform(delegate (int a) { throw new Exception("inner boom"); return a; }, 5);
	auto chained2 = future2.then((int a) => inner2);
	bool threw;
	try
		chained2.yieldForce();
	catch (Exception e)
	{
		threw = true;
		assert(e.msg == "inner boom");
	}
	assert(threw);
}
// ditto (コールバック自体が例外を投げた場合も外側がfailedになる)
@system unittest
{
	auto future3 = new Future!int;
	future3.perform(delegate (int a) => a + 10, 10);
	auto chained3 = future3.then((int a) {
		throw new Exception("callback boom");
		return new Future!int;
	});
	bool threw;
	try
		chained3.yieldForce();
	catch (Exception e)
	{
		threw = true;
		assert(e.msg == "callback boom");
	}
	assert(threw);
}
// ditto (既に完了済みの内側Futureにも正しくフラット化される)
@system unittest
{
	auto future4 = new Future!int;
	future4.perform(delegate (int a) => a + 10, 10);
	auto inner4 = new Future!int(999);
	auto chained4 = future4.then((int a) => inner4);
	assert(chained4.yieldForce() == 999);
}
// ditto (Future!void へのフラット化)
@system unittest
{
	auto future5 = new Future!int;
	future5.perform(delegate (int a) => a + 1, 1);
	auto innerVoid5 = new Future!void;
	bool ran;
	innerVoid5.perform(delegate () { ran = true; });
	auto chained5 = future5.then((int a) => innerVoid5);
	chained5.yieldForce();
	assert(ran);
}

/* *****************************************************************************
 * 以下、`-cov`によるカバレッジ計測結果に基づき追加した、異常系・境界値の
 * unittestブロック群。特にリカバリ用コールバック自身が例外/致命的エラーを
 * 投げた場合や、nullを返した場合などの異常系を網羅する。
 */
@system unittest
{
	import std.exception: collectException;
	// `evStart`引数を明示的に渡した場合、そちらもシグナルされる
	auto ev = new SyncEvent(false);
	auto future = new Future!int(new Exception("boom"), ev);
	assert(ev.signaled);
}
// Ret==voidのリカバリコールバックが致命的エラーを投げた場合
@system unittest
{
	import std.exception: collectException;
	auto future = new Future!void;
	future.perform(delegate () { throw new Exception("boom"); });
	auto d = future.then(() {}, (Exception e) { throw new Error("recovery fatal"); });
	auto err = collectException!Error(d.yieldForce());
	assert(err !is null && err.msg == "recovery fatal");
}
// 値を返すリカバリコールバックが例外/致命的エラーを投げた場合
@system unittest
{
	import std.exception: collectException;
	int delegate(Exception) throwsException = (Exception e) {
		throw new Exception("recovery failed");
	};
	auto future1 = new Future!int;
	future1.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e1 = collectException!Exception(future1.then((int a) => a + 1, throwsException).yieldForce());
	assert(e1 !is null && e1.msg == "recovery failed");
	
	int delegate(Exception) throwsError = (Exception e) {
		throw new Error("recovery fatal");
	};
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e2 = collectException!Error(future2.then((int a) => a + 1, throwsError).yieldForce());
	assert(e2 !is null && e2.msg == "recovery fatal");
}
// Futureを返すリカバリコールバックが例外/致命的エラーを投げる、またはnullを返した場合
@system unittest
{
	import std.exception: collectException;
	Future!int delegate(Exception) throwsException = (Exception e) {
		throw new Exception("recovery failed");
	};
	auto future1 = new Future!int;
	future1.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto d1 = future1.then((int a) => new Future!int(a + 1), throwsException);
	auto e1 = collectException!Exception(d1.yieldForce());
	assert(e1 !is null && e1.msg == "recovery failed");
	
	Future!int delegate(Exception) throwsError = (Exception e) {
		throw new Error("recovery fatal");
	};
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto d2 = future2.then((int a) => new Future!int(a + 1), throwsError);
	auto e2 = collectException!Error(d2.yieldForce());
	assert(e2 !is null && e2.msg == "recovery fatal");
	
	Future!int nullFuture;
	auto future3 = new Future!int;
	future3.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto d3 = future3.then((int a) => new Future!int(a + 1), (Exception e) => nullFuture);
	auto e3 = collectException!Exception(d3.yieldForce());
	assert(e3 !is null);
}
// exceptがFutureを返す場合のフラット化、および例外/致命的エラーを投げた場合
@system unittest
{
	import std.exception: collectException;
	auto future1 = new Future!int;
	future1.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto fallback = new Future!int(55);
	assert(future1.except((Exception e) => fallback).yieldForce() == 55);
	
	int delegate(Exception) throwsException = (Exception e) {
		throw new Exception("except failed");
	};
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e2 = collectException!Exception(future2.except(throwsException).yieldForce());
	assert(e2 !is null && e2.msg == "except failed");
	
	int delegate(Exception) throwsError = (Exception e) {
		throw new Error("except fatal");
	};
	auto future3 = new Future!int;
	future3.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e3 = collectException!Error(future3.except(throwsError).yieldForce());
	assert(e3 !is null && e3.msg == "except fatal");
}
// Ret==voidのexcept()に関する分岐: 型不一致・フラット化・例外/致命的エラーを投げた場合・元が致命的エラーの場合
@system unittest
{
	import std.exception: collectException, assertThrown;
	static class SpecificEx : Exception { this(string m) { super(m); } }
	
	// 型不一致(素通し)
	auto future1 = new Future!void;
	future1.perform(delegate () { throw new Exception("generic"); });
	assertThrown!Exception(future1.except!SpecificEx((SpecificEx e) {}).yieldForce());
	
	// Futureを返す(フラット化)
	auto future2 = new Future!void;
	future2.perform(delegate () { throw new Exception("boom"); });
	auto fallback2 = new Future!void;
	bool ran2;
	fallback2.perform(delegate () { ran2 = true; });
	future2.except((Exception e) => fallback2).yieldForce();
	assert(ran2);
	
	// コールバックが例外を投げる
	auto future3 = new Future!void;
	future3.perform(delegate () { throw new Exception("boom"); });
	auto e3 = collectException!Exception(future3.except((Exception e) {
		throw new Exception("except failed");
	}).yieldForce());
	assert(e3 !is null && e3.msg == "except failed");
	
	// コールバックが致命的エラーを投げる
	auto future4 = new Future!void;
	future4.perform(delegate () { throw new Exception("boom"); });
	auto e4 = collectException!Error(future4.except((Exception e) {
		throw new Error("except fatal");
	}).yieldForce());
	assert(e4 !is null && e4.msg == "except fatal");
	
	// 元が致命的エラーの場合、except()は素通りする
	auto future5 = new Future!void;
	future5.perform(delegate () { throw new Error("fatal"); });
	assertThrown!Error(future5.except((Exception e) {}).yieldForce());
}
// always()のコールバックが例外/致命的エラーを投げた場合の各パターン(成功/失敗/致命的エラー × 投げるものがException/Error)
@system unittest
{
	import std.exception: collectException;
	
	// void-Ret、成功時にalwaysコールバックが例外/致命的エラーを投げる
	auto future1 = new Future!void;
	future1.perform(delegate () {});
	auto e1 = collectException!Exception(future1.always(() {
		throw new Exception("finally failed");
	}).yieldForce());
	assert(e1 !is null && e1.msg == "finally failed");
	
	auto future2 = new Future!void;
	future2.perform(delegate () {});
	auto e2 = collectException!Error(future2.always(() {
		throw new Error("finally fatal");
	}).yieldForce());
	assert(e2 !is null && e2.msg == "finally fatal");
	
	// 非void、成功時にalwaysコールバックが致命的エラーを投げる
	auto future3 = new Future!int(10);
	auto e3 = collectException!Error(future3.always(() {
		throw new Error("finally fatal");
	}).yieldForce());
	assert(e3 !is null && e3.msg == "finally fatal");
	
	// 失敗時、alwaysコールバック自体が例外/致命的エラーを投げると上書きされる
	auto future4 = new Future!int;
	future4.perform(delegate (int a) { throw new Exception("original"); return a; }, 10);
	auto e4 = collectException!Exception(future4.always(() {
		throw new Exception("finally failed");
	}).yieldForce());
	assert(e4 !is null && e4.msg == "finally failed");
	
	auto future5 = new Future!int;
	future5.perform(delegate (int a) { throw new Exception("original"); return a; }, 10);
	auto e5 = collectException!Error(future5.always(() {
		throw new Error("finally fatal");
	}).yieldForce());
	assert(e5 !is null && e5.msg == "finally fatal");
	
	// 致命的エラー時、alwaysコールバック自体が例外/致命的エラーを投げると上書きされる
	auto future6 = new Future!int;
	future6.perform(delegate (int a) { throw new Error("original fatal"); return a; }, 10);
	auto e6 = collectException!Exception(future6.always(() {
		throw new Exception("finally failed");
	}).yieldForce());
	assert(e6 !is null && e6.msg == "finally failed");
	
	auto future7 = new Future!int;
	future7.perform(delegate (int a) { throw new Error("original fatal"); return a; }, 10);
	auto e7 = collectException!Error(future7.always(() {
		throw new Error("finally fatal 2");
	}).yieldForce());
	assert(e7 !is null && e7.msg == "finally fatal 2");
}
// alias func 版 then() でも明示的な callbackFailed でリカバリできる。
// `Ret2 = ReturnType!func` というデフォルトテンプレート引数機構のカバレッジ
@system unittest
{
	static int addOne(int a) { return a + 1; }
	auto future1 = new Future!int;
	future1.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	assert(future1.then!addOne((Exception e) => 999).yieldForce() == 999);
	
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	assert(future2.then!addOne(taskPool, (Exception e) => 888).yieldForce() == 888);
	
	static void noop() {}
	auto future3 = new Future!void;
	future3.perform(delegate () { throw new Exception("boom"); });
	bool recovered3;
	future3.then!noop((Exception e) { recovered3 = true; }).yieldForce();
	assert(recovered3);
	
	auto future4 = new Future!void;
	future4.perform(delegate () { throw new Exception("boom"); });
	bool recovered4;
	future4.then!noop(taskPool, (Exception e) { recovered4 = true; }).yieldForce();
	assert(recovered4);
	
	// alias func版 then() が Future を返す場合のフラット化(isFutureInstance!Ret2)
	static Future!int makeInner(int a) { return new Future!int(a * 10); }
	auto future5 = new Future!int;
	future5.perform(delegate (int a) => a + 1, 4);
	assert(future5.then!makeInner().yieldForce() == 50);
	
	static Future!void makeInnerVoid()
	{
		auto f = new Future!void;
		f.perform(delegate () {});
		return f;
	}
	auto future6 = new Future!void;
	future6.perform(delegate () {});
	future6.then!makeInnerVoid().yieldForce();
}
// exceptがFutureを返す形のコールバックで、そのコールバック自体が例外/致命的エラーを投げる、あるいはnullを返す場合
@system unittest
{
	import std.exception: collectException;
	
	Future!int delegate(Exception) throwsException = (Exception e) {
		throw new Exception("except failed");
	};
	auto future1 = new Future!int;
	future1.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e1 = collectException!Exception(future1.except(throwsException).yieldForce());
	assert(e1 !is null && e1.msg == "except failed");
	
	Future!int delegate(Exception) throwsError = (Exception e) {
		throw new Error("except fatal");
	};
	auto future2 = new Future!int;
	future2.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e2 = collectException!Error(future2.except(throwsError).yieldForce());
	assert(e2 !is null && e2.msg == "except fatal");
	
	Future!int nullFuture;
	auto future3 = new Future!int;
	future3.perform(delegate (int a) { throw new Exception("boom"); return a; }, 10);
	auto e3 = collectException!Exception(future3.except((Exception e) => nullFuture).yieldForce());
	assert(e3 !is null);
	
	// void-Ret版でも同様
	Future!void delegate(Exception) throwsExceptionVoid = (Exception e) {
		throw new Exception("except failed void");
	};
	auto future4 = new Future!void;
	future4.perform(delegate () { throw new Exception("boom"); });
	auto e4 = collectException!Exception(future4.except(throwsExceptionVoid).yieldForce());
	assert(e4 !is null && e4.msg == "except failed void");
	
	Future!void delegate(Exception) throwsErrorVoid = (Exception e) {
		throw new Error("except fatal void");
	};
	auto future5 = new Future!void;
	future5.perform(delegate () { throw new Exception("boom"); });
	auto e5 = collectException!Error(future5.except(throwsErrorVoid).yieldForce());
	assert(e5 !is null && e5.msg == "except fatal void");
	
	Future!void nullFutureVoid;
	auto future6b = new Future!void;
	future6b.perform(delegate () { throw new Exception("boom"); });
	auto e6 = collectException!Exception(future6b.except((Exception e) => nullFutureVoid).yieldForce());
	assert(e6 !is null);
}


/*******************************************************************************
 * 非同期処理の開始
 */
auto async()
{
	auto ret = new Future!void(SyncEvent.init);
	ret._type = Future!void.FinishedType.done;
	return ret;
}
@system unittest
{
	auto future = async();
	future.yieldForce();
	future.workForce();
	future.spinForce();
	future.join();
}
@system unittest
{
	auto future = new Future!int(10, SyncEvent.init);
	assert(future.result == 10);
	future.join();
	assert(future.yieldForce() == 10);
	assert(future.workForce() == 10);
	assert(future.spinForce() == 10);
}

/// ditto
auto async(F, Args...)(TaskPool pool, F dg, Args args)
	if (isCallable!F)
{
	auto ret = new Future!(ReturnType!F);
	_makeTask!_dgRun(ret, dg, args);
	ret._submit(pool);
	ret._evStart.signaled = true;
	return ret;
}
@system unittest
{
	auto future = async(taskPool, delegate (int a) => a + 10, 10);
	assert(future.yieldForce() == 20);
}

/// ditto
auto async(F, Args...)(F dg, Args args)
	if (isCallable!F)
{
	auto ret = new Future!(ReturnType!F);
	_makeTask!_dgRun(ret, dg, args);
	ret._task.executeInNewThread();
	ret._evStart.signaled = true;
	return ret;
}
@system unittest
{
	auto future = async(delegate (int a) => a + 20, 10);
	assert(future.yieldForce() == 30);
}
/// ditto
auto async(alias func, Args...)(TaskPool pool, Args args)
	if (is(typeof(func(args))))
{
	auto ret = new Future!(typeof(func(args)));
	_makeTask!func(ret, args);
	ret._submit(pool);
	ret._evStart.signaled = true;
	return ret;
}
@system unittest
{
	auto future = async!(a => a + 30)(taskPool, 10);
	assert(future.yieldForce() == 40);
}
/// ditto
auto async(alias func, Args...)(Args args)
	if (!is(Args[0] == TaskPool) && is(typeof(func(args))))
{
	auto ret = new Future!(typeof(func(args)));
	_makeTask!func(ret, args);
	ret._task.executeInNewThread();
	ret._evStart.signaled = true;
	return ret;
}
@system unittest
{
	auto future = async!(a => a + 40)(10);
	assert(future.yieldForce() == 50);
}

/*******************************************************************************
 * 管理された共有資源
 * 
 * 
 */
class ManagedShared(T): Object.Monitor
{
private:
	import std.exception;
	static struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy _proxy;
	Mutex        _mutex;
	size_t       _locked;
	T            _data;
	void _initData(bool initLocked)
	{
		_proxy.link = this;
		this.__monitor = &_proxy;
		_mutex = new Mutex();
		if (initLocked)
			lock();
	}
public:
	
	/***************************************************************************
	 * コンストラクタ
	 * 
	 * sharedのコンストラクタを呼んだ場合の初期状態は共有資源(unlockされた状態)
	 * 非sharedのコンストラクタを呼んだ場合の初期状態は非共有資源(lockされた状態)
	 */
	this()() @trusted
	{
		// これはひどい
		(cast(void delegate(bool) pure)&_initData)(true);
	}
	
	/// ditto
	this()() @trusted shared
	{
		(cast(void delegate(bool) pure)(&(cast()this)._initData))(false);
	}
	
	
	/***************************************************************************
	 * 
	 */
	inout(Mutex) mutex() pure nothrow @nogc inout @property
	{
		return _mutex;
	}
	
	
	/***************************************************************************
	 * 
	 */
	shared(inout(Mutex)) mutex() pure nothrow @nogc shared inout @property
	{
		return _mutex;
	}
	
	
	/***************************************************************************
	 * ロックされたデータを得る
	 * 
	 * この戻り値が破棄されるときにRAIIで自動的にロックが解除される。
	 * また、戻り値はロックされた共有資源へ、非共有資源としてアクセス可能な参照として使用できる。
	 */
	auto locked() @safe @property // @suppress(dscanner.confusing.function_attributes)
	{
		lock();
		static struct LockedData
		{
		private:
			T*              _data;
			void delegate() _unlock;
		public:
			ref inout(T) dataRef() inout @property { return *_data; }
			@disable this(this);
			~this() @trusted
			{
				if (_unlock)
					_unlock();
			}
			alias dataRef this;
		}
		return LockedData(&_data, &unlock);
	}
	/// ditto
	auto locked() @trusted shared inout @property
	{
		return (cast()this).locked();
	}
	
	
	/***************************************************************************
	 * ロックを試行する。
	 * 
	 * Returns:
	 *     すでにロックしているならtrue
	 *     ロックされていなければロックしてtrue
	 *     別のスレッドにロックされていてロックできなければfalse
	 */
	bool tryLock() @safe
	{
		auto tmp = (() @trusted => _mutex.tryLock())();
		// ロックされていなければ _locked を操作することは許されない
		if (tmp)
			_locked++;
		return tmp;
	}
	/// ditto
	bool tryLock() @trusted shared
	{
		return (cast()this).tryLock();
	}
	
	
	/***************************************************************************
	 * ロックする。
	 */
	void lock() @safe
	{
		_mutex.lock();
		_locked++;
	}
	/// ditto
	void lock() @trusted shared
	{
		(cast()this).lock();
	}
	
	
	/***************************************************************************
	 * ロック解除する。
	 */
	void unlock() @safe
	{
		_locked--;
		_mutex.unlock();
	}
	/// ditto
	void unlock() @trusted shared
	{
		(cast()this).unlock();
	}
	
	
	/***************************************************************************
	 * 非共有資源としてアクセスする
	 */
	ref T asUnshared() inout @property
	{
		enforce(_locked != 0);
		return *cast(T*)&_data;
	}
	/// ditto
	ref T asUnshared() shared inout @property
	{
		enforce(_locked != 0);
		return *cast(T*)&_data;
	}
	
	
	/***************************************************************************
	 * 共有資源としてアクセスする
	 */
	ref shared(T) asShared() inout @property
	{
		return *cast(shared(T)*)&_data;
	}
	/// ditto
	ref shared(T) asShared() shared inout @property
	{
		return *cast(shared(T)*)&_data;
	}
}


/*******************************************************************************
 * 
 */
ManagedShared!T managedShared(T)(T dat)
{
	import std.algorithm: move;
	auto s = new ManagedShared!T;
	s.asUnshared = dat.move();
	return s;
}

/// ditto
ManagedShared!T managedShared(T, Args...)(Args args)
{
	auto s = new ManagedShared!T;
	static if (Args.length == 0 && is(typeof(s.asUnshared.__ctor())))
	{
		s.asUnshared.__ctor();
	}
	else static if (is(typeof(s.asUnshared.__ctor(args))))
	{
		s.asUnshared.__ctor(args);
	}
	else static if (is(T == struct) && is(typeof(T(args))))
	{
		s.asUnshared = T(args);
	}
	return s;
}
@system unittest
{
	static struct TestData
	{
		string test;
	}
	static struct TestData2
	{
		string test;
		this(bool x)
		{
			test = x ? "test true" : "test false";
		}
	}
	auto s1 = managedShared(TestData("test"));
	s1.unlock();
	assert(s1.locked.test == "test");
	
	auto s2 = managedShared!TestData("test1");
	s2.unlock();
	assert(s2.locked.test == "test1");
	
	auto s3 = managedShared!TestData2(true);
	s3.unlock();
	assert(s3.locked.test == "test true");
}

@system unittest
{
	import core.atomic;
	auto s = managedShared!int();
	s.asUnshared += 50;
	s.asShared.atomicOp!"+="(100);
	s.unlock();
	try
	{
		s.asUnshared += 200;
		assert(0);
	}
	catch (Exception e) { }
	s.lock();
	s.asUnshared += 200;
	assert(s.asShared == 350);
	s.unlock();
	
	{
		auto ld = s.locked;
		assert(s._locked);
		ld += 1;
	}
	assert(!s._locked);
	assert(s.asShared == 351);
	
	synchronized (s)
	{
		assert(s._locked);
		{
			auto ld = s.locked;
			assert(s._locked);
			ld += 2;
		}
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 353);
}


@system unittest
{
	import core.atomic;
	auto s = new shared ManagedShared!int();
	try
	{
		s.asUnshared += 50;
	}
	catch (Exception e) { }
	assert(s.asShared == 0);
	s.asShared.atomicOp!"+="(100);
	s.lock();
	s.asUnshared += 200;
	assert(s.asShared == 300);
	s.unlock();
	try
	{
		s.asUnshared += 200;
		assert(0);
	}
	catch (Exception e) { }
	assert(s.asShared == 300);
	
	{
		auto ld = s.locked;
		assert(s._locked);
		ld += 1;
	}
	assert(!s._locked);
	assert(s.asShared == 301);
	
	synchronized (s)
	{
		assert(s._locked);
		{
			auto ld = s.locked;
			assert(s._locked);
			ld += 2;
		}
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 303);
}




/*******************************************************************************
 * マルチタスクキューによって管理されるタスクデータ
 */
class TaskData
{
	import std.datetime;
	import std.uuid;
	/// 状態
	enum State
	{
		/// 初期状態で、タスクプールに追加される前
		waiting,
		/// タスクプールに追加された状態
		ready,
		/// 実行中の状態
		running,
		/// 実行が終了した状態
		finished,
		/// 実行の結果、異常終了した状態
		failed,
		/// 実行されずにドロップされた状態
		dropped,
	}
protected:
	/// タスクの種類
	immutable string                 type;
	/// タスクの本体
	immutable void delegate() shared onCall;
	/// Queueに追加された時刻
	shared SysTime                   timCreate;
	/// Poolに追加された時刻
	shared SysTime                   timReady = SysTime.init;
	/// 実行開始した時刻
	shared SysTime                   timStart = SysTime.init;
	/// 実行終了した時刻
	shared SysTime                   timEnd = SysTime.init;
	/// 一意なID
	immutable UUID                   uuid;
	/// 状態
	State state = State.waiting;
	/// Poolに追加されたタイミングでコールバック
	void onReady() shared {  }
	/// 実行開始したタイミングでコールバック
	void onStart() shared {  }
	/// 実行終了したタイミングでコールバック
	void onEnd() shared {  }
	/// 実行失敗したタイミングでコールバック
	void onFailed(Throwable) shared {  }
	/// 実行されずにドロップしたタイミングでコールバック
	void onDropped() shared {  }
	
public:
	///
	this(string ty, void delegate() shared callback, UUID id = randomUUID())
	{
		type      = ty;
		onCall    = callback;
		timCreate = Clock.currTime();
		uuid      = cast(immutable)id;
	}
}

/*******************************************************************************
 * マルチタスクキュー
 * 
 * タスクの待ち行列を作成する。
 * 同じ種類のタスクは待ち行列によって順次実行し、違う種類のタスクはタスクプールで並列実行する。
 * コンストラクタでタスクプールの設定を行い、$(D invoke)関数によってタスクの種類と実行内容を指定する。
 * $(D invoke)により指定されるタスクは、$(D TaskData)クラスを継承することで細かく内容を調整することができる。
 * $(D invoke)によって待ち行列に追加された未だ実行されていないタスクを、$(D drop)によって実行取り消しすることができる。
 * $(D informations)関数により、各タスクの実行状況を調べることができる。
 * 
 * 以下のようなことが可能
 * 
 * <img src="img/voile.sync.MultiTaskQueue-testcase.drawio.svg" />
 */
class MultiTaskQueue
{
private:
	import core.atomic;
	import core.sync.mutex;
	import core.thread;
	import std.concurrency;
	import std.parallelism;
	import std.uuid;
	import std.datetime;
	
	TaskPool _pool;
	void delegate() _finishPool;
	
	struct TaskQueue
	{
	private:
		TaskData[][string] _tasks;
		enum State
		{
			ready, finish
		}
		State _state = State.ready;
	public:
		///
		void pushBack(TaskData task, void delegate() onCreated = null)
		{
			TaskData[] update(ref TaskData[] tasks)
			{
				onCreated = null;
				tasks ~= task;
				return tasks;
			}
			TaskData[] create()
			{
				return [task];
			}
			_tasks.update(task.type, &create, &update);
			if (onCreated !is null)
				onCreated();
		}
		///
		TaskData removeAt(string type, UUID uuid)
		{
			import std.algorithm: countUntil;
			import std.array: replaceInPlace;
			TaskData removed;
			TaskData[] update(ref TaskData[] tasks)
			{
				// 現在実行中のタスクには手を出さない
				if (tasks.length <= 1 || tasks[0].uuid == uuid)
					return tasks;
				auto removeIdx = tasks.countUntil!(e => e.uuid == uuid);
				if (removeIdx == -1)
					return tasks;
				removed = tasks[removeIdx];
				tasks.replaceInPlace(removeIdx, removeIdx+1, TaskData[].init);
				return tasks;
			}
			TaskData[] create()
			{
				return [];
			}
			_tasks.update(type, &create, &update);
			return removed;
		}
		///
		TaskData removeFront(string type)
		{
			TaskData ret;
			TaskData[] update(ref TaskData[] tasks)
			{
				if (tasks.length == 0)
					return tasks;
				ret = tasks[0];
				tasks = tasks[1..$];
				return tasks;
			}
			TaskData[] create()
			{
				return [];
			}
			_tasks.update(type, &create, &update);
			return ret;
		}
		///
		TaskData removeFrontAndGetNext(string type, out TaskData next)
		{
			TaskData ret;
			TaskData[] update(ref TaskData[] tasks)
			{
				if (tasks.length == 0)
					return tasks;
				ret = tasks[0];
				tasks = tasks[1..$];
				if (tasks.length > 0)
					next = tasks[0];
				return tasks;
			}
			TaskData[] create()
			{
				return [];
			}
			_tasks.update(type, &create, &update);
			return ret;
		}
		///
		TaskData refFront(string type)
		{
			import std.exception: enforce;
			return (*enforce(type in _tasks))[0];
		}
		///
		TaskData getFront(string type)
		{
			if (auto p = type in _tasks)
				if ((*p).length > 0)
					return (*p)[0];
			return null;
		}
		///
		TaskData getAt(string type, UUID id)
		{
			if (auto p = type in _tasks)
			{
				import std.algorithm, std.array;
				auto found = (*p).find!(a => a.uuid == id);
				if (!found.empty)
					return found.front;
			}
			return null;
		}
		/// 現在実行中の次のタスクを得る
		TaskData getNext(string type)
		{
			if (auto p = type in _tasks)
				if ((*p).length > 1)
					return (*p)[1];
			return null;
		}
		/// 現在実行中のタスクの次のタスクを破棄する。破棄されたタスクを返す。
		TaskData dropNext(string type)
		{
			import std.array: replaceInPlace;
			if (auto p = type in _tasks)
			{
				if ((*p).length > 1)
				{
					auto ret = (*p)[1];
					replaceInPlace(*p, 1, 2, cast(TaskData[])[]);
					return ret;
				}
			}
			return null;
		}
		///
		string[] types()
		{
			return _tasks.keys;
		}
	}
	shared ManagedShared!TaskQueue _taskQueue;
	
	void _startTask(string type) shared
	{
		void delegate(TaskData p, Throwable e) edTask;
		void delegate(TaskData p) stTask;
		edTask = (TaskData p, Throwable e)
		{
			auto tim = Clock.currTime();
			auto queue = _taskQueue.locked;
			assert(p.timStart.assumeUnshared !is SysTime.init);
			assert(p.timEnd.assumeUnshared    is SysTime.init);
			p.timEnd.assumeUnshared = tim;
			auto sp = cast(shared)p;
			TaskData next;
			auto currTsk = queue.removeFrontAndGetNext(type, next);
			assert(currTsk is p);
			if (e)
			{
				p.state = TaskData.State.failed;
				sp.onFailed(e);
			}
			else
			{
				p.state = TaskData.State.finished;
				sp.onEnd();
			}
			if (next)
				stTask(next);
		};
		stTask = (TaskData p)
		{
			assert(p.timReady.assumeUnshared is SysTime.init);
			assert(p.timStart.assumeUnshared is SysTime.init);
			p.timReady.assumeUnshared = Clock.currTime();
			p.state.assumeUnshared = TaskData.State.ready;
			auto sp = cast(shared)p;
			sp.onReady();
			_pool.assumeUnshared.put(task(
			{
				synchronized (_taskQueue)
				{
					p.state.assumeUnshared = TaskData.State.running;
					p.timStart.assumeUnshared = Clock.currTime();
				}
				sp.onStart();
				try
				{
					sp.onCall();
					edTask(p, null);
				}
				catch (Throwable e)
				{
					edTask(p, e);
				}
			}));
		};
		synchronized (_taskQueue)
			stTask(_taskQueue.asUnshared.refFront(type));
	}
	
	void _initialize(TaskPool pool, void delegate() finishPool)
	{
		_pool          = pool;
		_finishPool    = finishPool;
		_taskQueue     = new shared ManagedShared!TaskQueue;
	}
	
public:
	
	/***************************************************************************
	 * コンストラクタ
	 * 
	 * Params:
	 *      pool = 使用するタスクプールを指定できる
	 *      callbackFinishPool = タスクキューを破棄した際に全てのタスクが終了した際に呼ばれる。タスクプールを終了するために使用できる。
	 *      worker = ワーカースレッド数を指定して作成できる
	 *      daemon = スレッドのデーモン化をする場合はtrue。disposeしない場合がある場合にtrueを指定する。
	 */
	this(TaskPool pool, void delegate() callbackFinishPool = null)
	{
		this._initialize(pool, callbackFinishPool);
	}
	
	/// ditto
	this(TaskPool pool, void delegate() callbackFinishPool = null) shared
	{
		// コンストラクタにおいては、このインスタンスは間違いなく単一であるため
		// unsharedにキャストできる
		(cast()this)._initialize(pool, callbackFinishPool);
	}
	/// ditto
	this(size_t worker = 8, bool daemon = false)
	{
		this(new TaskPool(worker), () => _pool.finish(true));
		if (daemon)
			_pool.isDaemon = true;
	}
	/// ditto
	this(size_t worker = 8, bool daemon = false) shared
	{
		this(new TaskPool(worker), () => _pool.assumeUnshared.finish(true));
		if (daemon)
			_pool.assumeUnshared.isDaemon = true;
	}
	
	/***************************************************************************
	 * インスタンスを破棄する。
	 */
	void dispose()
	{
		with (_taskQueue.locked)
		{
			_state = State.finish;
			// 現在実行されていないすべてのデータを破棄
			foreach (ty; types)
			{
				TaskData t = dropNext(ty);
				while (t)
				{
					(cast(shared)t).onDropped();
					t = dropNext(ty);
				}
			}
		}
		if (_finishPool !is null)
			_finishPool();
	}
	
	/***************************************************************************
	 * タスクを実行予約する
	 * 
	 * タスクを待ち行列に追加する。待ち行列に追加されると、順次実行される。
	 * 待ち行列は$(D type)毎にあり、どの待ち行列に追加されるかはタスクの$(D type)により決まる。
	 * 同じ$(D type)では、追加された順に順次実行される。
	 * 異なる$(D type)の場合は並行して実行される。並行数はコンストラクタで指定したタスクプールに依存する。
	 * 
	 * Params:
	 *      tsk = タスクデータを指定する
	 *      type = タスク種別を指定する
	 *      dg = タスクの処理内容のデリゲートを指定する
	 *      id = タスクの識別用IDを指定する
	 * Returns:
	 *      タスクを追加することができたらtrueを、追加できなかったらfalseを返す。
	 */
	bool invoke(TaskData tsk)
	{
		with (_taskQueue.locked)
		{
			if (_state == State.ready)
			{
				pushBack(tsk);
				auto frontTask = refFront(tsk.type);
				if (frontTask.uuid == tsk.uuid)
					(cast(shared)this)._startTask(tsk.type);
				return true;
			}
		}
		return false;
	}
	/// ditto
	bool invoke(TaskData tsk) shared
	{
		// どちらもやることは同じ
		return (cast()this).invoke(tsk);
	}
	/// ditto
	bool invoke(string type, void delegate() shared dg, UUID id = randomUUID())
	{
		return invoke(new TaskData(type, dg, id));
	}
	/// ditto
	bool invoke(string type, void delegate() shared dg, UUID id = randomUUID()) shared
	{
		return invoke(new TaskData(type, dg, id));
	}
	
	/***************************************************************************
	 * タスク実行を取りやめる
	 * 
	 * タスクがまだ実行されていない場合は、実行を取りやめる。
	 * 
	 * Params:
	 *      type = タスク種別を指定する
	 *      id = タスクの識別用IDを指定する
	 * Returns:
	 *      正常にドロップされた場合はtrueが返り、さもなくばfalseが返る。
	 */
	bool drop(string type, UUID id)
	{
		with (_taskQueue.locked)
		{
			if (_state == State.ready)
			{
				if (auto t = removeAt(type, id))
				{
					(cast(shared)t).onDropped();
					return true;
				}
			}
		}
		return false;
	}
	
	/***************************************************************************
	 * タスクを取り出す
	 */
	shared(TaskData) peek(string type, UUID id)
	{
		with (_taskQueue.locked)
			return cast(shared)getAt(type, id);
	}
	
	
	/***************************************************************************
	 * タスクの情報
	 */
	struct TaskInfo
	{
		/// タスクの種類
		string         type;
		/// Queueに追加された時刻
		SysTime        timCreate;
		/// Poolに追加された時刻
		SysTime        timReady;
		/// 実行開始した時刻
		SysTime        timStart;
		/// 実行終了した時刻
		SysTime        timEnd;
		/// 一意なID
		UUID           uuid;
		/// タスクの状態
		alias State = TaskData.State;
		/// ditto
		State state;
	}
	
	/***************************************************************************
	 * 情報取得
	 * 
	 * タスクの実行状況を調べる。
	 * 
	 * Returns:
	 *      タスクの情報を$(D TaskInfo)の配列で返す。
	 */
	TaskInfo[] informations() const @safe @property
	{
		TaskInfo[] ret;
		with (_taskQueue.locked)
		{
			foreach (k, tasks; _tasks)
			{
				foreach (t; tasks)
					ret ~= TaskInfo(t.type, t.timCreate, t.timReady, t.timStart, t.timEnd, t.uuid, t.state);
			}
		}
		return ret;
	}
}

// <img src="img/voile.sync.MultiTaskQueue-testcase.drawio.svg" />
@system unittest
{
	import std;
	auto pool = new TaskPool(2);
	pool.isDaemon = true;
	auto mtq = new MultiTaskQueue(pool, () => pool.finish(false));
	scope (exit)
		mtq.dispose();
	UUID[][4] ids;
	
	class MyTaskData: TaskData
	{
		SyncEvent ended;
		SyncEvent started;
		SyncEvent kill;
		bool      fail;
		this(int grp, UUID id)
		{
			started = new SyncEvent(false);
			ended   = new SyncEvent(false);
			kill    = new SyncEvent(false);
			super(grp.text, &(cast(shared)this).onRun, id);
		}
		void onRun() shared
		{
			started.assumeUnshared.signaled = true;
			kill.assumeUnshared.wait();
			enforce(!fail);
		}
		override void onEnd() shared
		{
			ended.assumeUnshared.signaled = true;
		}
		override void onFailed(Throwable e) shared
		{
			ended.assumeUnshared.signaled = true;
		}
	}
	MyTaskData[][4] tasks;
	MyTaskData currentTask(size_t grp)
	{
		return cast(MyTaskData) mtq._taskQueue.locked.getFront(grp.text);
	}
	MyTaskData getTask(size_t grp, size_t idx)
	{
		return tasks[grp][idx];
	}
	size_t currentIdx(size_t grp)
	{
		if (auto tsk = currentTask(grp))
			return ids[grp].countUntil(tsk.uuid.assumeUnshared);
		return -1;
	}
	void wait(size_t grp)
	{
		currentTask(grp).started.wait();
	}
	void start(int grp)
	{
		auto id = randomUUID();
		auto tsk = new MyTaskData(grp, id);
		mtq.invoke(tsk);
		tasks[grp] ~= tsk;
		ids[grp]   ~= id;
	}
	void end(size_t grp)
	{
		auto tsk = currentTask(grp);
		tsk.kill.signaled = true;
		tsk.ended.wait();
	}
	void fail(size_t grp)
	{
		auto tsk = currentTask(grp);
		tsk.fail = true;
		tsk.kill.signaled = true;
		tsk.ended.wait();
	}
	void drop(size_t grp, size_t idx)
	{
		mtq.drop(grp.text, ids[grp][idx]);
	}
	
	
	start(1);
	start(2);
	start(3);
	
	wait(1);
	wait(2);
	
	// チェック1：ワーカースレッド以上の処理は動かさない
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(1) == 0);
		assert(currentIdx(2) == 0);
		assert(currentIdx(3) == 0);
		assert(getFront("1").state == TaskData.State.running);
		assert(getFront("2").state == TaskData.State.running);
		assert(getFront("3").state == TaskData.State.ready);
	}
	
	auto infos = mtq.informations;
	infos.sort!((a,b) => icmp(a.type, b.type) < 0, SwapStrategy.stable);
	assert(infos.length == 3);
	assert(infos[0].type == "1");
	assert(infos[1].type == "2");
	assert(infos[2].type == "3");
	assert(infos[0].state == TaskData.State.running);
	assert(infos[1].state == TaskData.State.running);
	assert(infos[2].state == TaskData.State.ready);
	
	end(1);
	wait(3);
	
	// チェック2：ワーカーが空くと自動でキューが消費される
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(1) == -1);
		assert(currentIdx(2) == 0);
		assert(currentIdx(3) == 0);
		assert(getFront("1") is null);
		assert(getFront("2").state == TaskData.State.running);
		assert(getFront("3").state == TaskData.State.running);
	}
	
	start(2);
	end(3);
	
	// チェック3：ワーカーが開いても前処理が終わっていないとキューは消費されない
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(2) == 0);
		assert(getAt("2", ids[2][1]).state == TaskData.State.waiting);
	}
	
	end(2);
	wait(2);
	
	// チェック4：前処理が終わるとキューが消費される
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(2) == 1);
		assert(getAt("2", ids[2][1]).state == TaskData.State.running);
	}
	
	
	start(3);
	start(3);
	start(3);
	drop(3, 2);
	wait(3);
	
	// チェック5：タスクをドロップする
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(3) == 1);
		assert(getAt("3", ids[3][1]).state == TaskData.State.running);
		assert(getAt("3", ids[3][2]) is null);
		assert(getAt("3", ids[3][3]).state == TaskData.State.waiting);
	}
	
	end(2);
	end(3);
	wait(3);
	
	// チェック6：ドロップされたタスクは実行されない
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(3) == 3);
		assert(getAt("3", ids[3][1]) is null);
		assert(getAt("3", ids[3][2]) is null);
		assert(getAt("3", ids[3][3]).state == TaskData.State.running);
	}
	fail(3);
	
	// チェック7：タスクの失敗がわかる
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(3) == -1);
		assert(getAt("3", ids[3][3]) is null);
		assert(getTask(3, 3).state == TaskData.State.failed);
	}
}

/*******************************************************************************
 * 
 */
class MessageQueue(T)
if (!hasUnsharedAliasing!T)
{
@safe:
private:
	import core.lifetime: move;
	import core.time: Duration, msecs;
	import core.sync.mutex: Mutex;
	import core.sync.condition: Condition;
	import std.container.dlist: DList;
	import std.range: put, isInputRange, isOutputRange;
	import std.exception: collectException;
	Condition _cond;
	DList!T _list;
	size_t  _length;
	shared(Mutex) _mutex() @trusted nothrow shared
	{
		try
			return _cond.mutex;
		catch (Exception)
			assert(0);
	}
	void _wait() @trusted nothrow
	{
		try
			_cond.wait();
		catch (Exception)
			assert(0);
	}
	bool _wait(Duration dur) @trusted nothrow
	{
		try
			return _cond.wait(dur);
		catch (Exception)
			assert(0);
	}
	void _notify() @trusted nothrow
	{
		cast(void)_cond.notifyAll().collectException();
	}
public:
	/***************************************************************************
	 * コンストラクタ
	 */
	this(return scope Condition cond) @system nothrow
	{
		_cond = cond;
	}
	/// ditto
	this() @system nothrow
	{
		this(new Condition(new Mutex));
	}
	/// ditto
	this(Condition cond) @trusted shared nothrow
	{
		_cond = cast(shared)cond;
	}
	/// ditto
	this(shared(Condition) cond) @safe shared nothrow
	{
		_cond = cond;
	}
	/// ditto
	this() @safe shared nothrow
	{
		this(new Condition(new Mutex));
	}
	
	/***************************************************************************
	 * 供給
	 */
	void put(T dat) nothrow
	{
		_list.insertBack(dat);
		++_length;
		_notify();
	}
	/// ditto
	void put(T dat) @trusted nothrow shared
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		(cast()this).put(dat.move);
	}
	/// ditto
	void put(Range)(Range src) nothrow
	if (isInputRange!Range && is(ForeachType!Range: T))
	{
		foreach (ref e; src)
		{
			_list.insertBack(e.move());
			++_length;
		}
		_notify();
	}
	/// ditto
	void put(Range)(Range src) @trusted nothrow shared
	if (isInputRange!Range && is(ForeachType!Range: T))
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		(cast()this).put(src);
	}
	
	/***************************************************************************
	 * 消費
	 */
	T consume() nothrow
	{
		while (_list.empty)
			_wait();
		scope (exit)
			_list.removeFront();
		--_length;
		return _list.front.move();
	}
	/// ditto
	T consume() nothrow shared @trusted
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		return (cast()this).consume();
	}
	/// ditto
	void consumeAll(OutputRange)(ref OutputRange dst) nothrow
	if (isOutputRange!(OutputRange, T))
	{
		while (_list.empty)
			_wait();
		foreach (ref e; _list[])
			put(dst, e.move);
		_list.clear();
		_length = 0;
	}
	/// ditto
	void consumeAll(OutputRange)(ref OutputRange dst) @trusted nothrow shared
	if (isOutputRange!(OutputRange, T))
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		return (cast()this).consumeAll(dst);
	}
	/// ditto
	bool tryConsume(ref T dst, Duration timeout = 0.msecs) nothrow
	{
		try
		{
			if (_list.empty && !_wait(timeout))
				return false;
			if (_list.empty)
				return false;
		}
		catch (Exception)
			return false;
		scope (exit)
			_list.removeFront();
		dst = _list.front.move();
		--_length;
		return true;
	}
	/// ditto
	bool tryConsume(ref T dst, Duration timeout = 0.msecs) @trusted nothrow shared
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		return (cast()this).tryConsume(dst, timeout);
	}
	/// ditto
	bool tryConsumeAll(OutputRange)(ref OutputRange dst, Duration timeout = 0.msecs) nothrow
	if (isOutputRange!(OutputRange, T))
	{
		if (_list.empty && !_wait(timeout))
			return false;
		if (_list.empty)
			return false;
		foreach (ref e; _list[])
			put(dst, e.move);
		_list.clear();
		_length = 0;
		return true;
	}
	/// ditto
	bool tryConsumeAll(OutputRange)(ref OutputRange dst, Duration timeout = 0.msecs) @trusted nothrow shared
	if (isOutputRange!(OutputRange, T))
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		return (cast()this).tryConsumeAll(dst, timeout);
	}
	
	/***************************************************************************
	 * データ供給待ち
	 */
	bool waitForData() nothrow
	{
		if (_list.empty)
			_wait();
		return !_list.empty;
	}
	/// ditto
	bool waitForData() @trusted nothrow shared
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		return (cast()this).waitForData();
	}
	/// ditto
	bool waitForData(Duration timeout) nothrow
	{
		if (_list.empty)
			_wait(timeout);
		return !_list.empty;
	}
	/// ditto
	bool waitForData(Duration timeout) @trusted nothrow shared
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		return (cast()this).waitForData(timeout);
	}
	
	/***************************************************************************
	 * 現在の待ち行列の長さ
	 */
	size_t length() @trusted nothrow const @property
	{
		return _length;
	}
	/// ditto
	size_t length() @trusted nothrow const shared @property
	{
		import core.atomic;
		return _length.atomicLoad();
	}
	
	/***************************************************************************
	 * とじる
	 */
	void close(bool waitForConsume = false) nothrow
	{
		if (waitForConsume && !_list.empty)
			_wait();
		_length = 0;
		_notify();
	}
	/// ditto
	void close(bool waitForConsume = false) @trusted shared nothrow
	{
		auto m = _mutex;
		m.lock_nothrow();
		scope (exit)
			m.unlock_nothrow();
		(cast()this).close(waitForConsume);
	}
}


@system unittest
{
	import core.thread;
	import core.sync.barrier;
	auto tg = new ThreadGroup;
	auto queue = new shared MessageQueue!string;
	auto b = new Barrier(2);
	string[] test;
	// producer
	tg.create({
		b.wait();
		queue.put("aaa");
		queue.put("bbb");
		queue.put(["ccc", "ddd"]);
		b.wait();
		queue.put(["eee", "fff"]);
		b.wait();
	});
	// consumer
	tg.create({
		b.wait();
		test ~= queue.consume();
		string tmp;
		auto tryres = queue.tryConsume(tmp, 100.msecs);
		assert(tryres);
		test ~= tmp;
		import std.array;
		auto app = appender!(string[]);
		queue.consumeAll(app);
		b.wait();
		tryres = queue.tryConsumeAll(app, 100.msecs);
		assert(tryres);
		test ~= app.data;
		b.wait();
		assert(queue.length == 0);
	});
	
	tg.joinAll();
	assert(test == ["aaa", "bbb", "ccc", "ddd", "eee", "fff"]);
}

/*******************************************************************************
 * 
 */
class MessageBox(T, Key = string)
if (!hasUnsharedAliasing!T)
{
@safe:
private:
	import core.lifetime: move;
	import core.time: Duration, msecs;
	import std.container.dlist: DList;
	import std.range: put, isInputRange, isOutputRange;
	import std.exception: collectException;
	version (Have_vibe_core)
	{
		import vibe.core.core: Task;
		enum bool _isVibeTask = is(Key == Task);
	}
	else
	{
		enum bool _isVibeTask = false;
	}
	import std.concurrency: Tid, thisTid;
	enum bool _isTid = is(Key == Tid);
	import core.thread: Thread, ThreadID, Fiber;
	enum bool _isFiber = is(Key == Fiber);
	enum bool _isThread = is(Key == Thread);
	static if (_isVibeTask)
	{
		alias MapKey = Fiber;
		enum bool _hasDefaultKey = true;
		pragma(inline, true) static MapKey _mapkey(Key k) { return k.fiber(); }
		pragma(inline, true) static Key _defaultKey() nothrow { return Task.getThis; }
	}
	else static if (_isTid)
	{
		alias MapKey = Tid;
		enum bool _hasDefaultKey = true;
		pragma(inline, true) static MapKey _mapkey(Key k) { return k; }
		pragma(inline, true) static Key _defaultKey() nothrow
		{
			try
				return thisTid();
			catch (Exception)
				assert(0);
		}
	}
	else static if (_isFiber)
	{
		alias MapKey = Fiber;
		enum bool _hasDefaultKey = true;
		pragma(inline, true) static MapKey _mapkey(Key k) { return k; }
		pragma(inline, true) static Key _defaultKey() { return Fiber.getThis(); }
	}
	else static if (_isThread)
	{
		alias MapKey = ThreadID;
		enum bool _hasDefaultKey = true;
		pragma(inline, true) static MapKey _mapkey(Key k) { return k.id; }
		pragma(inline, true) static Key _defaultKey() { return Thread.getThis; }
	}
	else
	{
		alias MapKey = Key;
		enum bool _hasDefaultKey = false;
		pragma(inline, true) static MapKey _mapkey(Key k) { return k; }
		pragma(inline, true) static Key _defaultKey() { return MapKey.init; }
	}
	alias Queue = shared(MessageQueue!T);
	shared ManagedShared!(Queue[MapKey]) _map;
	
	pragma(inline, true) Queue _reqQueue(Key k) @trusted nothrow
	{
		try
		{
			synchronized (_map)
				return _map.asUnshared.require(_mapkey(k), new Queue);
		}
		catch (Exception)
			assert(0);
	}
	pragma(inline, true) Queue _reqQueue(Key k) shared @trusted nothrow { return (cast()this)._reqQueue(k); }
	pragma(inline, true) Queue _getQueue(Key k) @trusted nothrow
	{
		try
		{
			synchronized (_map)
				return _map.asUnshared.get(_mapkey(k), null);
		}
		catch (Exception)
			return null;
	}
	pragma(inline, true) Queue _getQueue(Key k) shared @trusted nothrow { return (cast()this)._getQueue(k); }
	pragma(inline, true) void _removeQueue(Key k) @trusted nothrow
	{
		try
		{
			synchronized (_map)
				_map.asUnshared.remove(_mapkey(k));
		}
		catch (Exception)
			assert(0);
	}
	pragma(inline, true) void _removeQueue(Key k) shared @trusted nothrow { return (cast()this)._removeQueue(k); }
	pragma(inline, true) Queue[] _allQueue() @trusted nothrow
	{
		try
		{
			Queue[] ret;
			synchronized (_map)
				foreach (q; _map.asUnshared.byValue)
					ret ~= q;
			return ret;
		}
		catch (Exception)
			assert(0);
	}
	pragma(inline, true) Queue[] _allQueue() shared @trusted nothrow { return (cast()this)._allQueue(); }
	pragma(inline, true) void _clearQueue() @trusted nothrow
	{
		try
		{
			synchronized (_map)
				_map.asUnshared.clear();
		}
		catch (Exception)
			assert(0);
	}
	pragma(inline, true) void _clearQueue() shared @trusted nothrow { return (cast()this)._clearQueue(); }
	
public:
	/***************************************************************************
	 * コンストラクタ
	 */
	this() shared
	{
		_map = new shared ManagedShared!(Queue[MapKey]);
	}
	/// ditto
	this() @system
	{
		_map = cast()new shared ManagedShared!(Queue[MapKey]);
	}
	
	/***************************************************************************
	 * 供給
	 */
	void put(Key key, T dat) nothrow shared
	{
		_reqQueue(key).put(dat);
	}
	/// ditto
	void put()(T dat) nothrow shared
	if (_hasDefaultKey)
	{
		put(_defaultKey(), dat.move);
	}
	/// ditto
	void put(Range)(Key key, Range dat) nothrow shared
	if (isInputRange!Range && is(ForeachType!Range: T))
	{
		_reqQueue(key).put(dat);
	}
	/// ditto
	void put(Range)(Range src) nothrow shared
	if (_hasDefaultKey && isInputRange!Range && is(ForeachType!Range: T))
	{
		put(_defaultKey(), src);
	}
	
	/***************************************************************************
	 * 消費
	 */
	T consume(Key key) nothrow shared
	{
		return _reqQueue(key).consume();
	}
	/// ditto
	T consume()() nothrow shared
	if (_hasDefaultKey)
	{
		return consume(_defaultKey());
	}
	/// ditto
	void consumeAll(OutputRange)(Key key, ref OutputRange dst) nothrow shared
	if (isOutputRange!(OutputRange, T))
	{
		_reqQueue(key).consumeAll(dst);
	}
	/// ditto
	void consumeAll(OutputRange)(ref OutputRange dst) nothrow shared
	if (_hasDefaultKey && isOutputRange!(OutputRange, T))
	{
		consumeAll(_defaultKey(), dst);
	}
	/// ditto
	bool tryConsume(Key key, ref T dst, Duration timeout = 0.msecs) nothrow shared
	{
		return _reqQueue(key).tryConsume(dst, timeout);
	}
	/// ditto
	bool tryConsume()(ref T dst, Duration timeout = 0.msecs) nothrow shared
	if (_hasDefaultKey)
	{
		return tryConsume(_defaultKey(), dst, timeout);
	}
	/// ditto
	bool tryConsumeAll(OutputRange)(Key key, ref OutputRange dst, Duration timeout = 0.msecs) nothrow shared
	if (isOutputRange!(OutputRange, T))
	{
		return _reqQueue(key).tryConsumeAll(dst, timeout);
	}
	/// ditto
	bool tryConsumeAll(OutputRange)(ref OutputRange dst, Duration timeout = 0.msecs) nothrow shared
	if (_hasDefaultKey && isOutputRange!(OutputRange, T))
	{
		return tryConsumeAll(_defaultKey(), dst, timeout);
	}
	
	/***************************************************************************
	 * データ供給待ち
	 */
	bool waitForData(Key key) nothrow shared
	{
		return _reqQueue(key).waitForData();
	}
	/// ditto
	bool waitForData()() nothrow shared
	if (_hasDefaultKey)
	{
		return waitForData(_defaultKey());
	}
	/// ditto
	bool waitForData(Key key, Duration timeout) nothrow shared
	{
		return _reqQueue(key).waitForData(timeout);
	}
	/// ditto
	bool waitForData()(Duration timeout) nothrow shared
	if (_hasDefaultKey)
	{
		return waitForData(_defaultKey(), timeout);
	}
	
	
	/***************************************************************************
	 * とじる
	 */
	void close(Key key, bool waitForConsume = false) nothrow shared
	{
		_reqQueue(key).close();
		_removeQueue(key);
	}
	/// ditto
	void close()(bool waitForConsume = false) nothrow shared
	if (_hasDefaultKey)
	{
		close(_defaultKey(), waitForConsume);
	}
	/// ditto
	void closeAll(bool waitForConsume = false) nothrow shared
	{
		foreach (q; _allQueue)
			q.close(waitForConsume);
		_clearQueue();
	}
	
	/***************************************************************************
	 * Queueにアクセス
	 */
	Queue opIndex(Key key) nothrow shared
	{
		return _reqQueue(key);
	}
	/// ditto
	Queue opBinaryRight(string op: "in")(Key key) nothrow shared
	{
		return _getQueue(key);
	}
}

@system unittest
{
	import core.thread;
	import core.sync.barrier;
	auto tg = new ThreadGroup;
	auto msgbox = new shared MessageBox!string;
	auto b = new Barrier(2);
	string[] test;
	// producer
	tg.create({
		b.wait();
		msgbox["1"].put("aaa");
		msgbox.put("2", "bbb");
		msgbox["3"].put(["ccc", "ddd"]);
		b.wait();
		msgbox.put("1", ["eee", "fff"]);
		b.wait();
	});
	// consumer
	tg.create({
		b.wait();
		test ~= msgbox.consume("1");
		string tmp;
		auto tryres = msgbox["2"].tryConsume(tmp, 100.msecs);
		assert(tryres);
		test ~= tmp;
		import std.array;
		auto app = appender!(string[]);
		msgbox.consumeAll("3", app);
		b.wait();
		tryres = msgbox["1"].tryConsumeAll(app, 100.msecs);
		assert(tryres);
		test ~= app.data;
		b.wait();
	});
	
	tg.joinAll();
	assert("1" in msgbox);
	assert("x" !in msgbox);
	msgbox.closeAll();
	assert("1" !in msgbox);
	assert(test == ["aaa", "bbb", "ccc", "ddd", "eee", "fff"]);
}
