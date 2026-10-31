import type { ProjectEntry } from '@dsh-solo/protocol'

interface DesktopProject {
  id: string
  title: string
  path: string
  status(): Promise<'ok' | 'missing-dir'>
  attachSession(id: string): Promise<void>
}
interface Registry {
  list(): DesktopProject[]
  get(id: string): DesktopProject | undefined
}

export async function listProjects(registry: Registry): Promise<ProjectEntry[]> {
  const available = await Promise.all(registry.list().map(async project =>
    await project.status() === 'ok' ? { id: project.id, title: project.title } : null,
  ))
  return available.filter((project): project is ProjectEntry => project !== null)
}

export async function requireProject(registry: Registry, id: string): Promise<DesktopProject> {
  const project = registry.get(id)
  if (!project || await project.status() !== 'ok') throw new Error('Project unavailable; refresh the project list')
  return project
}
