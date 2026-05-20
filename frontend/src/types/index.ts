export type DownloadStatus = 'queued' | 'downloading' | 'complete' | 'failed' | 'cancelled'

export interface DownloadItem {
  id: string
  url: string
  quality: string
  status: DownloadStatus
  title: string | null
  progress: number
  speed: string | null
  eta: string | null
  error: string | null
  created_at: string
  completed_at: string | null
}

export type Quality = 'best' | '1080p' | '720p' | '480p' | '360p' | 'audio'

export interface VideoInfo {
  title: string
  is_playlist: boolean
  count: number
  thumbnail: string | null
  duration: number | null
}
