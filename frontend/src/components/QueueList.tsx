import { X, Clock, Zap } from 'lucide-react'
import type { DownloadItem } from '../types'

export default function QueueList({ items }: { items: DownloadItem[] }) {
  if (items.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-slate-500">
        <Clock size={32} className="mb-3 opacity-40" />
        <p className="text-sm">No active downloads</p>
      </div>
    )
  }

  return (
    <ul className="space-y-3">
      {items.map(item => (
        <QueueCard key={item.id} item={item} />
      ))}
    </ul>
  )
}

function QueueCard({ item }: { item: DownloadItem }) {
  const isActive = item.status === 'downloading'

  const cancel = async () => {
    await fetch(`/api/queue/${item.id}`, { method: 'DELETE' })
  }

  return (
    <li className="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4 space-y-3">
      {/* Header row */}
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium text-slate-100 truncate leading-snug">
            {item.title ?? truncateUrl(item.url)}
          </p>
          {item.title && (
            <p className="text-xs text-slate-500 truncate mt-0.5">{item.url}</p>
          )}
        </div>
        <div className="flex items-center gap-2 flex-shrink-0">
          <StatusBadge status={item.status} />
          {item.status === 'queued' && (
            <button
              onClick={cancel}
              className="p-1.5 rounded-lg text-slate-500 hover:text-slate-300
                         hover:bg-slate-700 transition-colors"
              title="Cancel"
            >
              <X size={14} />
            </button>
          )}
        </div>
      </div>

      {/* Progress bar */}
      {isActive && (
        <>
          <div className="w-full bg-slate-700 rounded-full h-1.5 overflow-hidden">
            <div
              className="h-full rounded-full bg-gradient-to-r from-violet-600 to-violet-400
                         transition-all duration-300"
              style={{ width: `${item.progress}%` }}
            />
          </div>
          <div className="flex items-center justify-between text-xs text-slate-400">
            <div className="flex items-center gap-1">
              <Zap size={11} className="text-violet-400" />
              <span>{item.speed ?? '—'}</span>
            </div>
            <span>{item.progress.toFixed(1)}%</span>
            <div className="flex items-center gap-1">
              <Clock size={11} />
              <span>ETA {item.eta ?? '—'}</span>
            </div>
          </div>
        </>
      )}

      {/* Quality pill */}
      <div className="flex items-center gap-2">
        <span className="text-xs text-slate-500 bg-slate-700/60 rounded-md px-2 py-0.5">
          {qualityLabel(item.quality)}
        </span>
      </div>
    </li>
  )
}

function StatusBadge({ status }: { status: DownloadItem['status'] }) {
  const map: Record<DownloadItem['status'], { label: string; cls: string }> = {
    queued:      { label: 'Queued',      cls: 'bg-slate-700 text-slate-300' },
    downloading: { label: 'Downloading', cls: 'bg-violet-900/60 text-violet-300 animate-pulse' },
    complete:    { label: 'Complete',    cls: 'bg-emerald-900/60 text-emerald-300' },
    failed:      { label: 'Failed',      cls: 'bg-red-900/60 text-red-300' },
    cancelled:   { label: 'Cancelled',   cls: 'bg-slate-700 text-slate-400' },
  }
  const { label, cls } = map[status]
  return (
    <span className={`text-xs font-medium px-2 py-0.5 rounded-md ${cls}`}>
      {label}
    </span>
  )
}

function truncateUrl(url: string) {
  try {
    const u = new URL(url)
    return u.hostname + u.pathname.slice(0, 20)
  } catch {
    return url.slice(0, 40)
  }
}

function qualityLabel(q: string) {
  const map: Record<string, string> = {
    best: 'Best quality', '1080p': '1080p HD', '720p': '720p HD',
    '480p': '480p', '360p': '360p', audio: 'Audio only',
  }
  return map[q] ?? q
}
