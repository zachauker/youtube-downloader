import { useState, useRef } from 'react'
import { Download, Link, Loader2, Music, Film, ListVideo } from 'lucide-react'
import type { Quality, VideoInfo } from '../types'

const QUALITIES: { value: Quality; label: string }[] = [
  { value: 'best',  label: 'Best quality' },
  { value: '1080p', label: '1080p HD' },
  { value: '720p',  label: '720p HD' },
  { value: '480p',  label: '480p' },
  { value: '360p',  label: '360p' },
  { value: 'audio', label: 'Audio only (MP3)' },
]

export default function DownloadForm({ onAdded }: { onAdded?: () => void }) {
  const [url, setUrl]           = useState('')
  const [quality, setQuality]   = useState<Quality>('best')
  const [info, setInfo]         = useState<VideoInfo | null>(null)
  const [fetching, setFetching] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError]       = useState<string | null>(null)
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const fetchInfo = async (rawUrl: string) => {
    const trimmed = rawUrl.trim()
    if (!trimmed) { setInfo(null); return }
    setFetching(true)
    setError(null)
    try {
      const res = await fetch(`/api/info?url=${encodeURIComponent(trimmed)}`)
      if (!res.ok) {
        const err = await res.json().catch(() => ({ detail: 'Invalid URL' }))
        setError(err.detail ?? 'Could not fetch video info')
        setInfo(null)
      } else {
        setInfo(await res.json())
      }
    } catch {
      setError('Could not reach server')
      setInfo(null)
    } finally {
      setFetching(false)
    }
  }

  const handleUrlChange = (val: string) => {
    setUrl(val)
    setInfo(null)
    setError(null)
    if (debounceRef.current) clearTimeout(debounceRef.current)
    if (val.trim()) {
      debounceRef.current = setTimeout(() => fetchInfo(val), 600)
    }
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!url.trim() || submitting) return
    setSubmitting(true)
    try {
      await fetch('/api/download', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url.trim(), quality }),
      })
      setUrl('')
      setInfo(null)
      setError(null)
      onAdded?.()
    } catch {
      setError('Failed to add download')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {/* URL input */}
      <div className="relative">
        <div className="absolute inset-y-0 left-0 pl-3.5 flex items-center pointer-events-none">
          {fetching
            ? <Loader2 size={16} className="text-slate-400 animate-spin" />
            : <Link size={16} className="text-slate-400" />
          }
        </div>
        <input
          type="text"
          value={url}
          onChange={e => handleUrlChange(e.target.value)}
          placeholder="Paste a YouTube video or playlist URL…"
          className="w-full bg-slate-800 border border-slate-700 rounded-xl pl-9 pr-4 py-3 text-sm
                     text-slate-100 placeholder-slate-500 outline-none
                     focus:border-violet-500 focus:ring-1 focus:ring-violet-500/40
                     transition-colors"
        />
      </div>

      {/* Preview card */}
      {info && (
        <div className="flex items-center gap-3 p-3 bg-slate-800/60 border border-slate-700/60 rounded-xl">
          {info.thumbnail && (
            <img
              src={info.thumbnail}
              alt=""
              className="w-20 h-12 object-cover rounded-lg flex-shrink-0"
            />
          )}
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium text-slate-100 truncate">{info.title}</p>
            <div className="flex items-center gap-1.5 mt-0.5 text-xs text-slate-400">
              {info.is_playlist
                ? <><ListVideo size={12} /><span>{info.count} videos in playlist</span></>
                : info.duration
                  ? <><Film size={12} /><span>{formatDuration(info.duration)}</span></>
                  : null
              }
            </div>
          </div>
        </div>
      )}

      {/* Error */}
      {error && (
        <p className="text-xs text-red-400 px-1">{error}</p>
      )}

      {/* Quality + Submit row */}
      <div className="flex gap-3">
        <div className="relative flex-1">
          <select
            value={quality}
            onChange={e => setQuality(e.target.value as Quality)}
            className="w-full appearance-none bg-slate-800 border border-slate-700 rounded-xl
                       px-3 py-3 pr-8 text-sm text-slate-100 outline-none cursor-pointer
                       focus:border-violet-500 focus:ring-1 focus:ring-violet-500/40
                       transition-colors"
          >
            {QUALITIES.map(q => (
              <option key={q.value} value={q.value}>{q.label}</option>
            ))}
          </select>
          <div className="absolute inset-y-0 right-0 pr-3 flex items-center pointer-events-none">
            {quality === 'audio'
              ? <Music size={14} className="text-violet-400" />
              : <Film size={14} className="text-slate-400" />
            }
          </div>
        </div>

        <button
          type="submit"
          disabled={!url.trim() || submitting || fetching}
          className="flex items-center gap-2 bg-violet-600 hover:bg-violet-500
                     disabled:bg-slate-700 disabled:text-slate-500 disabled:cursor-not-allowed
                     text-white text-sm font-medium px-5 py-3 rounded-xl
                     transition-colors cursor-pointer"
        >
          {submitting
            ? <Loader2 size={15} className="animate-spin" />
            : <Download size={15} />
          }
          <span>Download</span>
        </button>
      </div>
    </form>
  )
}

function formatDuration(secs: number) {
  const h = Math.floor(secs / 3600)
  const m = Math.floor((secs % 3600) / 60)
  const s = secs % 60
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`
  return `${m}:${pad(s)}`
}

function pad(n: number) {
  return String(n).padStart(2, '0')
}
