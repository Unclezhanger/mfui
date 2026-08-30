import { NextResponse } from 'next/server'
import { listFolders } from '../_lib/config'

export async function GET() {
  const { exists, folders } = listFolders()
  return NextResponse.json({ exists, folders })
}
