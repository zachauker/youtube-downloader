import { useEffect, useRef, useState } from 'react'
import { Youtube, Wifi, WifiOff } from 'lucide-react'
import DownloadForm from './components/DownloadForm'
import QueueList from './components/QueueList'
import HistoryList from './components/HistoryList'
import type { DownloadItem } from './types'

type Tab = 'queue' | 'history'

export default function App() {
  const [items, setItems]         = useState<Record<string, DownloadItem>>({})
  const [history, setHistory]     = useState<DownloadItem[]>([])
  const [tab, setTab]             = useState<Tab>('queue')
  const [connected, setConnected] = useState(false)
  const esRef = useRef<EventSource | null>(null)

  // Load history once on mount
  useEffect(() => {
    fetch('/api/history')
      .then(r => r.json())
      .then(setHistory)
      .catch(() => {})
  }, [])

  // SSE for live updates
  useEffect(() => {
    const connect = () => {
      const es = new EventSource('/api/events')
      esRef.current = es

      es.onopen = () => setConnected(true)

      es.onmessage = (e) => {
        if (!e.data || e.data.startsWith(':')) return
        try {
          const { type, data } = JSON.parse(e.data) as { type: string; data: DownloadItem }
          if (type === 'update') {
            setItems(prev => ({ ...prev, [data.id]: data }))

            // Mirror completed / failed items into history
            if (data.status === 'complete' || data.status === 'failed') {
              setHistory(prev => {
                const filtered = prev.filter(h => h.id !== data.id)
                return [data, ...filtered]
              })
            }
          }
        } catch {/* ignore malformed */ }
      }

      es.onerror = () => {
        setConnected(false)
        es.close()
        setTimeout(connect, 3000)
      }
    }

    connect()
    return () => esRef.current?.close()
  }, [])

  const queueItems = Object.values(items).filter(
    i => i.status === 'queued' || i.status === 'downloading',
  )

  return (
    <div className="min-h-screen bg-slate-950 flex flex-col">
      {/* Header */}
      <header className="border-b border-slate-800 px-6 py-4">
        <div className="max-w-2xl mx-auto flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-lg bg-violet-600 flex items-center justify-center">
              <Youtube size={16} className="text-white" />
            </div>
            <span className="font-semibold text-slate-100 tracking-tight">YT Downloader</span>
          </div>
          <div className="flex items-center gap-1.5 text-xs">
            {connected
              ? <><Wifi size={13} className="text-emerald-400" /><span className="text-emerald-400">Live</span></>
              : <><WifiOff size={13} className="text-slate-500" /><span className="text-slate-500">Reconnecting…</span></>
            }
          </div>
        </div>
      </header>

      <main className="flex-1 px-6 py-8">
        <div className="max-w-2xl mx-auto space-y-6">

          {/* Download form card */}
          <section className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
            <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-4">
              Add Download
            </h2>
            <DownloadForm onAdded={() => setTab('queue')} />
          </section>

          {/* Queue / History card */}
          <section className="bg-slate-900 border border-slate-800 rounded-2xl overflow-hidden">
            {/* Tabs */}
            <div className="flex border-b border-slate-800">
              <TabButton active={tab === 'queue'} onClick={() => setTab('queue')}>
                Queue
                {queueItems.length > 0 && (
                  <span className="ml-2 text-xs bg-violet-600 text-white rounded-full
                                   w-5 h-5 inline-flex items-center justify-center font-medium">
                    {queueItems.length}
                  </span>
                )}
              </TabButton>
              <TabButton active={tab === 'history'} onClick={() => setTab('history')}>
                History
              </TabButton>
            </div>

            <div className="p-5">
              {tab === 'queue'
                ? <QueueList items={queueItems} />
                : <HistoryList items={history} />
              }
            </div>
          </section>
        </div>
      </main>
    </div>
  )
}

function TabButton({
  active, onClick, children,
}: {
  active: boolean
  onClick: () => void
  children: React.ReactNode
}) {
  return (
    <button
      onClick={onClick}
      className={`flex items-center px-5 py-3.5 text-sm font-medium transition-colors cursor-pointer
        ${active
          ? 'text-violet-400 border-b-2 border-violet-500 -mb-px'
          : 'text-slate-500 hover:text-slate-300'
        }`}
    >
      {children}
    </button>
  )
}
