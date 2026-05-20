import { CheckCircle2, XCircle, History } from 'lucide-react'
import type { DownloadItem } from '../types'

export default function HistoryList({ items }: { items: DownloadItem[] }) {
  if (items.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-slate-500">
        <History size={32} className="mb-3 opacity-40" />
        <p className="text-sm">No download history yet</p>
      </div>
    )
  }

  return (
    <ul className="divide-y divide-slate-800">
      {items.map(item => (
        <HistoryRow key={item.id} item={item} />
      ))}
    </ul>
  )
}

function HistoryRow({ item }: { item: DownloadItem }) {
  const ok = item.status === 'complete'

  return (
    <li className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
      {ok
        ? <CheckCircle2 size={16} className="text-emerald-400 flex-shrink-0" />
        : <XCircle     size={16} className="text-red-400 flex-shrink-0" />
      }
      <div className="min-w-0 flex-1">
        <p className="text-sm text-slate-200 truncate leading-snug">
          {item.title ?? truncateUrl(item.url)}
        </p>
        <div className="flex items-center gap-2 mt-0.5">
          <span className="text-xs text-slate-500">
            {qualityLabel(item.quality)}
          </span>
          {item.completed_at && (
            <>
              <span className="text-slate-700">·</span>
              <span className="text-xs text-slate-500">
                {relativeTime(item.completed_at)}
              </span>
            </>
          )}
        </div>
        {item.error && (
          <p className="text-xs text-red-400 mt-0.5 truncate" title={item.error}>
            {item.error}
          </p>
        )}
      </div>
    </li>
  )
}

function truncateUrl(url: string) {
  try {
    const u = new URL(url)
    return u.hostname + u.pathname.slice(0, 30)
  } catch {
    return url.slice(0, 50)
  }
}

function qualityLabel(q: string) {
  const map: Record<string, string> = {
    best: 'Best', '1080p': '1080p', '720p': '720p',
    '480p': '480p', '360p': '360p', audio: 'Audio',
  }
  return map[q] ?? q
}

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1)  return 'just now'
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24)  return `${hrs}h ago`
  return `${Math.floor(hrs / 24)}d ago`
}
