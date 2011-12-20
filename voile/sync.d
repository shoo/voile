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


import core.thread, core.sync.mutex, core.sync.condition;

version (Windows)
{
	private enum uint INFINITE = 0xFFFFFFFF;
	private enum uint WAIT_OBJECT_0 = 0x00000000;
	private alias void* HANDLE;
	private extern(Windows) uint WaitForSingleObject(in HANDLE, uint);
	private extern(Windows) int CloseHandle(in HANDLE);
	private extern(Windows) HANDLE CreateEventW(void*, int, int, void*);
	private extern(Windows) int SetEvent(in HANDLE);
	private extern(Windows) int ResetEvent(in HANDLE);
}

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
		private static HANDLE createEvent(bool aFirstCondition = false)
		{
			auto h = CreateEventW(null, 1, aFirstCondition ? 1 : 0, null);
			return h;
		}
		private static void closeEvent(HANDLE h)
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
		 * Params: aHandle = イベントハンドル
		 */
		this(HANDLE h)
		{
			_ownHandle = false;
			_handle = h;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: aFirstCondition = 初期状態
		 */
		this(bool firstCondition = false)
		{
			_ownHandle = true;
			_handle = createEvent(firstCondition);
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
			return WaitForSingleObject(_handle, 0) == WAIT_OBJECT_0;
		}
		/***********************************************************************
		 * シグナル状態を設定する
		 * 
		 * Params: aCondition=
		 *     trueならシグナル状態にし、waitしているスレッドの制御を返す。
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるまで制御を
		 *     返さない状態にする。
		 */
		@property void signaled(bool cond)
		{
			if (cond && signaled == false)
			{
				SetEvent(_handle);
			}
			else if(signaled == true)
			{
				ResetEvent(_handle);
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるまで制御を
		 * 返さない。
		 */
		void wait()
		{
			WaitForSingleObject(_handle, INFINITE);
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(Duration dir)
		{
			return WaitForSingleObject(_handle, cast(uint)dir.total!"msecs")
				== WAIT_OBJECT_0;
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
		@property
		Condition handle()
		{
			return _condition;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: aFirstCondition = 初期状態
		 */
		this(bool firstCondition = false)
		{
			_signaled = firstCondition;
			_mutex = new Mutex;
			_condition = new Condition(_mutex);
		}
		/***********************************************************************
		 * シグナル状態を返す
		 * 
		 * Returns:
		 *     trueならシグナル状態で、waitはすぐに制御を返す
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるか、時間が
		 *     過ぎるまで制御を返さない状態であることを示す。
		 */
		@property
		bool signaled()
		{
			synchronized (_mutex)
			{
				return _signaled;
			}
		}
		/***********************************************************************
		 * シグナル状態を設定する
		 * 
		 * Params: aCondition=
		 *     trueならシグナル状態にし、waitしているスレッドの制御を返す。
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるまで制御を
		 *     返さない状態にする。
		 */
		@property
		void signaled(bool aCondition)
		{
			synchronized (_mutex)
			{
				_signaled = aCondition;
				_condition.notifyAll;
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるまで制御を
		 * 返さない。
		 */
		void wait()
		{
			synchronized (_mutex)
			{
				while (! _signaled) _condition.wait;
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(double period)
		{
			synchronized (_mutex)
			{
				while (! _signaled) _condition.wait(period);
				return _signaled;
			}
		}
	}
}

unittest
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




version (Posix)
{
	version (Tango)
	{
		private import tango.stdc.posix.semaphore;
		private import tango.stdc.posix.fcntl;
		private import tango.stdc.posix.sys.stat: S_IRWXU, S_IRWXG, S_IRWXO;
		private static const s777 = S_IRWXU|S_IRWXG|S_IRWXO;
		private import tango.stdc.errno;
	}
	else
	{
		private import core.sys.posix.semaphore;
		private import core.sys.posix.fcntl;
		private import core.sys.posix.sys.stat: S_IRWXU, S_IRWXG, S_IRWXO;
		private static const s777 = S_IRWXU|S_IRWXG|S_IRWXO;
		private import core.stdc.errno;
	}
	private alias sem_t* HANDLE;
}
else version (Windows)
{
	version (Tango)
	{
		private import tango.sys.Common: CreateMutexW, ReleaseMutex;
	}
	else
	{
		private extern (Windows) HANDLE CreateMutexW(void*,int,in wchar*);
		private extern (Windows) int ReleaseMutex(in HANDLE);
	}
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
	struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy m_Proxy;
	version(D_Version2)
	{
	}
	else
	{
		alias char[] string;
	}
	const HANDLE _handle;
	const string m_Name;
	version (Posix) const string m_SavedName;
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
			alias char char_t;
		}
		else version (Windows)
		{
			alias wchar char_t;
		}
		char_t[1024*4] buf;
		static char_t[] encodeStr(string str, char_t[] aBuf)
		{
			auto dBuf = aBuf;
			dBuf[0.."/voile::NamedMutex[".length] = "/voile::NamedMutex[";
			size_t j="/voile::NamedMutex[".length;
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
			if (j >= dBuf.length - 1) dBuf.length = dBuf.length + 2;
			dBuf[j++] = ']';
			dBuf[j++] = '\0';
			return dBuf[0..j];
		}
		version (Posix)
		{
			auto tmpname = m_SavedName = encodeStr(name, buf);
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
	@property const string name()
	{
		return m_Name;
	}
	
	/***************************************************************************
	 * デストラクタ
	 * 
	 * 名前付きミューテックスの削除を行う
	 */
	~this()
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
	void lock()
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
	bool tryLock()
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
	void unlock()
	{
		version (Posix)
		{
			sem_post(_handle);
		}
		else version (Windows)
		{
			ReleaseMutex(_handle);
		}
	}
}
