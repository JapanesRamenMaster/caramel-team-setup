# 스킬 카탈로그 — Plan C: 카탈로그 사이트

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 팀원이 스킬을 탐색·설치·제출할 수 있는 웹 카탈로그를 구축하고 Vercel에 배포한다.

**Architecture:** Next.js App Router. GitHub API로 `caramel-team-setup/skills/` 실시간 읽기 (SSOT는 Git). 제출 폼은 `incoming/` 폴더에 파일을 생성하는 GitHub API 호출로 연결. Vercel Edge Cache로 응답 캐싱.

**Tech Stack:** Next.js 15 (App Router), TypeScript, Tailwind CSS 4, Vercel, GitHub REST API (`@octokit/rest`), `gray-matter` (frontmatter 파싱)

**선행 조건:** Plan A 완료 (스킬에 프론트매터 있음)

---

## 파일 구조

```
caramel-skills-catalog/   (the-trive/caramel-skills-catalog — 신규 레포)
  app/
    page.tsx              → 스킬 목록 메인 페이지
    skills/[name]/
      page.tsx            → 스킬 상세 페이지
    submit/
      page.tsx            → 스킬 제출 폼 (client component)
    layout.tsx            → 공통 레이아웃
    globals.css           → Tailwind 전역 스타일
  components/
    SkillCard.tsx         → 스킬 카드 컴포넌트
    SideEffectBadge.tsx   → 🔴/🔒 뱃지
    SearchBar.tsx         → 검색바 (client component)
    TagFilter.tsx         → 태그 필터 (client component)
    CopyButton.tsx        → 설치 커맨드 클립보드 복사 버튼 (client component)
  lib/
    github.ts             → GitHub API 클라이언트 + 스킬 목록/상세 fetcher
    types.ts              → Skill 타입 정의
  next.config.ts          → Next.js 설정
  package.json
  .env.local              → GITHUB_TOKEN (로컬 개발용)
  .env.example
  vercel.json             → Vercel 설정
```

---

### Task 1: 레포 초기화

**Files:**
- Create: `package.json`, `next.config.ts`, `app/layout.tsx`, `app/globals.css`

- [ ] **Step 1: Next.js 프로젝트 생성**

```bash
cd ~/Desktop
npx create-next-app@latest caramel-skills-catalog \
  --typescript \
  --tailwind \
  --app \
  --no-src-dir \
  --import-alias "@/*" \
  --no-git

cd caramel-skills-catalog
npm install @octokit/rest gray-matter
```

- [ ] **Step 2: GitHub 레포 생성 및 초기화**

```bash
cd ~/Desktop/caramel-skills-catalog
git init
git add .
git commit -m "chore: Next.js 프로젝트 초기화"

gh repo create the-trive/caramel-skills-catalog \
  --private \
  --description "카라멜 팀 스킬 카탈로그" \
  --source=. \
  --push
```

- [ ] **Step 3: .env 파일 설정**

`.env.local`:
```
GITHUB_TOKEN=ghp_...   # caramel-team-setup read 권한 PAT
GITHUB_REPO_OWNER=JapanesRamenMaster
GITHUB_REPO_NAME=caramel-team-setup
```

`.env.example`:
```
GITHUB_TOKEN=
GITHUB_REPO_OWNER=JapanesRamenMaster
GITHUB_REPO_NAME=caramel-team-setup
```

- [ ] **Step 4: .gitignore에 .env.local 확인**

```bash
grep ".env.local" .gitignore || echo ".env.local" >> .gitignore
```

---

### Task 2: 타입 정의 및 GitHub API 클라이언트

**Files:**
- Create: `lib/types.ts`
- Create: `lib/github.ts`

- [ ] **Step 1: 타입 정의**

`lib/types.ts`:
```typescript
export type SideEffect =
  | "db-write"
  | "db-read"
  | "notification"
  | "slack-send"
  | "file-write"
  | "deploy"
  | "api-call"
  | "api-call-write";

export interface Skill {
  name: string;
  description: string;
  scope: "team" | "personal";
  owner: string;
  sideEffects: SideEffect[];
  requires?: string[];
  disableModelInvocation?: boolean;
  tags?: string[];
  version?: string;
  body: string;          // 프론트매터 제외한 본문 (마크다운)
  installCommand: string; // curl 설치 커맨드
}

export const DANGEROUS_EFFECTS: SideEffect[] = [
  "db-write", "notification", "slack-send", "deploy", "api-call-write"
];
```

- [ ] **Step 2: GitHub API 클라이언트**

`lib/github.ts`:
```typescript
import { Octokit } from "@octokit/rest";
import matter from "gray-matter";
import { Skill, SideEffect } from "./types";

const octokit = new Octokit({ auth: process.env.GITHUB_TOKEN });

const OWNER = process.env.GITHUB_REPO_OWNER!;
const REPO = process.env.GITHUB_REPO_NAME!;
const SKILLS_PATH = "skills";

function buildInstallCommand(skillName: string): string {
  return `curl -fsSL https://raw.githubusercontent.com/${OWNER}/${REPO}/main/${SKILLS_PATH}/${skillName}/SKILL.md -o ~/.claude/skills/${skillName} && echo "✅ ${skillName} 설치됨"`;
}

function parseSkillFile(name: string, content: string): Skill {
  const { data, content: body } = matter(content);
  return {
    name: data.name || name,
    description: data.description || "",
    scope: data.scope || "personal",
    owner: data.owner || "",
    sideEffects: (data["side-effects"] as SideEffect[]) || [],
    requires: data.requires,
    disableModelInvocation: data["disable-model-invocation"] || false,
    tags: data.tags,
    version: data.version,
    body,
    installCommand: buildInstallCommand(name),
  };
}

export async function getSkills(): Promise<Skill[]> {
  const { data: tree } = await octokit.repos.getContent({
    owner: OWNER,
    repo: REPO,
    path: SKILLS_PATH,
  });

  if (!Array.isArray(tree)) return [];

  const skills = await Promise.all(
    tree
      .filter((item) => item.type === "dir")
      .map(async (dir) => {
        try {
          const { data: file } = await octokit.repos.getContent({
            owner: OWNER,
            repo: REPO,
            path: `${SKILLS_PATH}/${dir.name}/SKILL.md`,
          });

          if ("content" in file) {
            const content = Buffer.from(file.content, "base64").toString("utf-8");
            const skill = parseSkillFile(dir.name, content);
            return skill.scope === "team" ? skill : null;
          }
          return null;
        } catch {
          return null;
        }
      })
  );

  return skills.filter((s): s is Skill => s !== null);
}

export async function getSkill(name: string): Promise<Skill | null> {
  try {
    const { data: file } = await octokit.repos.getContent({
      owner: OWNER,
      repo: REPO,
      path: `${SKILLS_PATH}/${name}/SKILL.md`,
    });

    if ("content" in file) {
      const content = Buffer.from(file.content, "base64").toString("utf-8");
      return parseSkillFile(name, content);
    }
    return null;
  } catch {
    return null;
  }
}

export async function submitSkillToIncoming(
  skillName: string,
  skillContent: string,
  submitterName: string,
  githubToken: string
): Promise<string> {
  const userOctokit = new Octokit({ auth: githubToken });
  const path = `incoming/${skillName}.md`;

  const { data: pr } = await userOctokit.repos.createOrUpdateFileContents({
    owner: OWNER,
    repo: REPO,
    path,
    message: `feat: ${skillName} 스킬 제출 (by ${submitterName})`,
    content: Buffer.from(skillContent).toString("base64"),
  });

  return pr.commit.html_url;
}
```

- [ ] **Step 3: 컴파일 확인**

```bash
npx tsc --noEmit
```

예상: 오류 없음

---

### Task 3: 공통 컴포넌트

**Files:**
- Create: `components/SideEffectBadge.tsx`
- Create: `components/CopyButton.tsx`

- [ ] **Step 1: SideEffectBadge**

`components/SideEffectBadge.tsx`:
```tsx
import { SideEffect, DANGEROUS_EFFECTS } from "@/lib/types";

const LABELS: Record<SideEffect, string> = {
  "db-write": "DB 쓰기",
  "db-read": "DB 조회",
  "notification": "알림톡",
  "slack-send": "슬랙 발송",
  "file-write": "파일 쓰기",
  "deploy": "배포",
  "api-call": "API 호출",
  "api-call-write": "API 쓰기",
};

export function SideEffectBadge({ effect }: { effect: SideEffect }) {
  const isDangerous = DANGEROUS_EFFECTS.includes(effect);
  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${
        isDangerous
          ? "bg-red-100 text-red-700"
          : "bg-gray-100 text-gray-600"
      }`}
    >
      {isDangerous ? "🔴" : "⚪"} {LABELS[effect] || effect}
    </span>
  );
}

export function LockBadge() {
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-700">
      🔒 사람만 실행
    </span>
  );
}
```

- [ ] **Step 2: CopyButton**

`components/CopyButton.tsx`:
```tsx
"use client";
import { useState } from "react";

export function CopyButton({ text, label = "복사" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <button
      onClick={async () => {
        await navigator.clipboard.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      }}
      className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium rounded-md bg-gray-900 text-white hover:bg-gray-700 transition-colors"
    >
      {copied ? "✅ 복사됨" : `📋 ${label}`}
    </button>
  );
}
```

---

### Task 4: SkillCard 컴포넌트

**Files:**
- Create: `components/SkillCard.tsx`

- [ ] **Step 1: SkillCard 작성**

`components/SkillCard.tsx`:
```tsx
import Link from "next/link";
import { Skill, DANGEROUS_EFFECTS } from "@/lib/types";
import { SideEffectBadge, LockBadge } from "./SideEffectBadge";
import { CopyButton } from "./CopyButton";

export function SkillCard({ skill }: { skill: Skill }) {
  const hasDangerousEffects = skill.sideEffects.some((e) =>
    DANGEROUS_EFFECTS.includes(e)
  );

  return (
    <div className="border border-gray-200 rounded-xl p-5 hover:border-gray-300 hover:shadow-sm transition-all bg-white">
      <div className="flex items-start justify-between gap-3 mb-3">
        <Link
          href={`/skills/${skill.name}`}
          className="text-base font-semibold text-gray-900 hover:text-blue-600 font-mono"
        >
          /{skill.name}
        </Link>
        <div className="flex gap-1.5 flex-shrink-0">
          {skill.disableModelInvocation && <LockBadge />}
          {hasDangerousEffects && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-red-50 text-red-600">
              🔴 사이드 이펙트
            </span>
          )}
        </div>
      </div>

      <p className="text-sm text-gray-600 mb-3 line-clamp-2">
        {skill.description.split("\n")[0]}
      </p>

      {skill.sideEffects.length > 0 && (
        <div className="flex flex-wrap gap-1.5 mb-3">
          {skill.sideEffects.map((e) => (
            <SideEffectBadge key={e} effect={e} />
          ))}
        </div>
      )}

      {skill.tags && skill.tags.length > 0 && (
        <div className="flex flex-wrap gap-1 mb-4">
          {skill.tags.map((tag) => (
            <span key={tag} className="text-xs text-gray-500 bg-gray-50 px-2 py-0.5 rounded">
              {tag}
            </span>
          ))}
        </div>
      )}

      <div className="flex items-center justify-between">
        <span className="text-xs text-gray-400">@{skill.owner}</span>
        <CopyButton text={skill.installCommand} label="설치 커맨드 복사" />
      </div>
    </div>
  );
}
```

---

### Task 5: SearchBar + TagFilter (Client Components)

**Files:**
- Create: `components/SearchBar.tsx`
- Create: `components/TagFilter.tsx`
- Create: `components/SkillGrid.tsx`

- [ ] **Step 1: SearchBar**

`components/SearchBar.tsx`:
```tsx
"use client";

export function SearchBar({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <input
      type="search"
      placeholder="스킬 이름, 설명, 태그로 검색..."
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="w-full px-4 py-2.5 border border-gray-200 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 bg-white"
    />
  );
}
```

- [ ] **Step 2: SkillGrid (검색+필터 통합 Client Component)**

`components/SkillGrid.tsx`:
```tsx
"use client";
import { useState, useMemo } from "react";
import { Skill } from "@/lib/types";
import { SkillCard } from "./SkillCard";
import { SearchBar } from "./SearchBar";

export function SkillGrid({ skills }: { skills: Skill[] }) {
  const [query, setQuery] = useState("");
  const [activeTag, setActiveTag] = useState<string | null>(null);

  const allTags = useMemo(
    () => [...new Set(skills.flatMap((s) => s.tags || []))].sort(),
    [skills]
  );

  const filtered = useMemo(
    () =>
      skills.filter((s) => {
        const matchesQuery =
          !query ||
          s.name.includes(query) ||
          s.description.toLowerCase().includes(query.toLowerCase()) ||
          (s.tags || []).some((t) => t.includes(query));
        const matchesTag = !activeTag || (s.tags || []).includes(activeTag);
        return matchesQuery && matchesTag;
      }),
    [skills, query, activeTag]
  );

  return (
    <div>
      <div className="mb-4">
        <SearchBar value={query} onChange={setQuery} />
      </div>

      {allTags.length > 0 && (
        <div className="flex flex-wrap gap-2 mb-6">
          <button
            onClick={() => setActiveTag(null)}
            className={`px-3 py-1 rounded-full text-sm ${
              !activeTag
                ? "bg-gray-900 text-white"
                : "bg-gray-100 text-gray-600 hover:bg-gray-200"
            }`}
          >
            전체
          </button>
          {allTags.map((tag) => (
            <button
              key={tag}
              onClick={() => setActiveTag(activeTag === tag ? null : tag)}
              className={`px-3 py-1 rounded-full text-sm ${
                activeTag === tag
                  ? "bg-gray-900 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              {tag}
            </button>
          ))}
        </div>
      )}

      {filtered.length === 0 ? (
        <p className="text-center text-gray-400 py-12">검색 결과 없음</p>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {filtered.map((skill) => (
            <SkillCard key={skill.name} skill={skill} />
          ))}
        </div>
      )}
    </div>
  );
}
```

---

### Task 6: 메인 페이지

**Files:**
- Create: `app/page.tsx`
- Create: `app/layout.tsx`

- [ ] **Step 1: layout.tsx**

`app/layout.tsx`:
```tsx
import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "카라멜 스킬 카탈로그",
  description: "카라멜 팀 Claude Code 스킬 모음",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="ko">
      <body className="bg-gray-50 min-h-screen">
        <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
          <div className="max-w-6xl mx-auto px-4 h-14 flex items-center justify-between">
            <a href="/" className="font-semibold text-gray-900">
              🍬 카라멜 스킬 카탈로그
            </a>
            <a
              href="/submit"
              className="text-sm px-4 py-1.5 bg-gray-900 text-white rounded-lg hover:bg-gray-700"
            >
              스킬 제출
            </a>
          </div>
        </header>
        <main className="max-w-6xl mx-auto px-4 py-8">{children}</main>
      </body>
    </html>
  );
}
```

- [ ] **Step 2: 메인 페이지 (app/page.tsx)**

`app/page.tsx`:
```tsx
import { getSkills } from "@/lib/github";
import { SkillGrid } from "@/components/SkillGrid";
import { unstable_cache } from "next/cache";

const getCachedSkills = unstable_cache(getSkills, ["skills"], {
  revalidate: 300, // 5분 캐시
});

export default async function HomePage() {
  const skills = await getCachedSkills();

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900 mb-1">
          팀 스킬 카탈로그
        </h1>
        <p className="text-gray-500 text-sm">
          {skills.length}개 스킬 · Claude Code에서 바로 설치 가능
        </p>
      </div>
      <SkillGrid skills={skills} />
    </div>
  );
}
```

- [ ] **Step 3: 로컬 실행 확인**

```bash
cd ~/Desktop/caramel-skills-catalog
npm run dev
# http://localhost:3000 에서 스킬 목록 확인
```

예상: 스킬 카드 11개 표시, 검색 동작

---

### Task 7: 스킬 상세 페이지

**Files:**
- Create: `app/skills/[name]/page.tsx`

- [ ] **Step 1: 상세 페이지 작성**

`app/skills/[name]/page.tsx`:
```tsx
import { notFound } from "next/navigation";
import { getSkill, getSkills } from "@/lib/github";
import { SideEffectBadge, LockBadge } from "@/components/SideEffectBadge";
import { CopyButton } from "@/components/CopyButton";
import { unstable_cache } from "next/cache";
import ReactMarkdown from "react-markdown";

export async function generateStaticParams() {
  const skills = await getSkills();
  return skills.map((s) => ({ name: s.name }));
}

export default async function SkillDetailPage({
  params,
}: {
  params: { name: string };
}) {
  const skill = await unstable_cache(
    () => getSkill(params.name),
    [`skill-${params.name}`],
    { revalidate: 300 }
  )();

  if (!skill) notFound();

  return (
    <div className="max-w-3xl">
      <a href="/" className="text-sm text-gray-400 hover:text-gray-600 mb-6 inline-block">
        ← 목록으로
      </a>

      <div className="bg-white rounded-xl border border-gray-200 p-8">
        <div className="flex items-start justify-between gap-4 mb-4">
          <h1 className="text-xl font-bold font-mono text-gray-900">
            /{skill.name}
          </h1>
          <div className="flex gap-2 flex-wrap justify-end">
            {skill.disableModelInvocation && <LockBadge />}
            {skill.sideEffects.map((e) => (
              <SideEffectBadge key={e} effect={e} />
            ))}
          </div>
        </div>

        <p className="text-gray-600 mb-6 whitespace-pre-line">{skill.description}</p>

        {skill.requires && skill.requires.length > 0 && (
          <div className="mb-6 p-4 bg-amber-50 rounded-lg border border-amber-100">
            <p className="text-sm font-semibold text-amber-800 mb-2">⚠️ 전제조건</p>
            <ul className="text-sm text-amber-700 space-y-1">
              {skill.requires.map((r) => (
                <li key={r} className="flex items-center gap-2">
                  <span className="font-mono text-xs bg-amber-100 px-1.5 py-0.5 rounded">{r}</span>
                  <span>환경변수 필요</span>
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className="mb-6">
          <p className="text-sm font-semibold text-gray-700 mb-2">📋 설치</p>
          <div className="bg-gray-900 rounded-lg p-3 flex items-center justify-between gap-3">
            <code className="text-xs text-green-400 font-mono break-all flex-1">
              {skill.installCommand}
            </code>
            <CopyButton text={skill.installCommand} />
          </div>
        </div>

        {skill.tags && skill.tags.length > 0 && (
          <div className="flex gap-2 mb-6">
            {skill.tags.map((tag) => (
              <span key={tag} className="text-xs bg-gray-100 text-gray-600 px-2 py-0.5 rounded">
                {tag}
              </span>
            ))}
          </div>
        )}

        <div className="prose prose-sm max-w-none border-t border-gray-100 pt-6">
          <ReactMarkdown>{skill.body}</ReactMarkdown>
        </div>

        <p className="text-xs text-gray-400 mt-6">관리자: @{skill.owner}</p>
      </div>
    </div>
  );
}
```

```bash
npm install react-markdown
```

- [ ] **Step 2: 로컬 확인**

```bash
# http://localhost:3000/skills/zone-change 접속
# 상세 페이지, 사이드 이펙트 뱃지, 설치 커맨드 확인
```

---

### Task 8: 제출 폼 페이지

**Files:**
- Create: `app/submit/page.tsx`
- Create: `app/api/submit/route.ts`

- [ ] **Step 1: API Route (GitHub PR 생성)**

`app/api/submit/route.ts`:
```typescript
import { NextRequest, NextResponse } from "next/server";
import { Octokit } from "@octokit/rest";

const OWNER = process.env.GITHUB_REPO_OWNER!;
const REPO = process.env.GITHUB_REPO_NAME!;

export async function POST(req: NextRequest) {
  const { skillName, skillContent, submitterName } = await req.json();

  if (!skillName || !skillContent || !submitterName) {
    return NextResponse.json({ error: "필수 항목 누락" }, { status: 400 });
  }

  const octokit = new Octokit({ auth: process.env.GITHUB_TOKEN });

  try {
    const path = `incoming/${skillName}.md`;
    const { data } = await octokit.repos.createOrUpdateFileContents({
      owner: OWNER,
      repo: REPO,
      path,
      message: `feat: ${skillName} 스킬 제출 (by ${submitterName})`,
      content: Buffer.from(skillContent).toString("base64"),
    });

    return NextResponse.json({
      commitUrl: data.commit.html_url,
      message: "제출 완료! Claude Opus가 곧 처리합니다.",
    });
  } catch (error) {
    console.error(error);
    return NextResponse.json({ error: "제출 실패" }, { status: 500 });
  }
}
```

- [ ] **Step 2: 제출 폼 페이지**

`app/submit/page.tsx`:
```tsx
"use client";
import { useState } from "react";

export default function SubmitPage() {
  const [skillName, setSkillName] = useState("");
  const [skillContent, setSkillContent] = useState("");
  const [submitterName, setSubmitterName] = useState("");
  const [status, setStatus] = useState<"idle" | "loading" | "done" | "error">("idle");
  const [resultUrl, setResultUrl] = useState("");

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus("loading");

    const res = await fetch("/api/submit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ skillName, skillContent, submitterName }),
    });

    if (res.ok) {
      const data = await res.json();
      setResultUrl(data.commitUrl);
      setStatus("done");
    } else {
      setStatus("error");
    }
  }

  if (status === "done") {
    return (
      <div className="max-w-xl mx-auto text-center py-16">
        <div className="text-4xl mb-4">🎉</div>
        <h2 className="text-xl font-bold text-gray-900 mb-2">제출 완료!</h2>
        <p className="text-gray-500 mb-6">
          Claude Opus가 프론트매터를 보강한 뒤 PR을 생성합니다. 보통 1-2분 걸려요.
        </p>
        <div className="flex gap-3 justify-center">
          <a
            href={resultUrl}
            target="_blank"
            className="px-4 py-2 bg-gray-900 text-white rounded-lg text-sm hover:bg-gray-700"
          >
            커밋 확인 →
          </a>
          <a href="/" className="px-4 py-2 bg-gray-100 text-gray-700 rounded-lg text-sm hover:bg-gray-200">
            카탈로그로 돌아가기
          </a>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-xl">
      <h1 className="text-xl font-bold text-gray-900 mb-1">스킬 제출</h1>
      <p className="text-sm text-gray-500 mb-6">
        스킬 내용만 있으면 됩니다. 프론트매터는 Claude Opus가 자동으로 채워줍니다.
      </p>

      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="text-sm font-medium text-gray-700 block mb-1">
            스킬 이름 <span className="text-red-500">*</span>
          </label>
          <input
            value={skillName}
            onChange={(e) => setSkillName(e.target.value.toLowerCase().replace(/\s+/g, "-"))}
            placeholder="my-skill-name"
            className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-500"
            required
          />
        </div>

        <div>
          <label className="text-sm font-medium text-gray-700 block mb-1">
            제출자 이름 (슬랙 핸들 또는 이름) <span className="text-red-500">*</span>
          </label>
          <input
            value={submitterName}
            onChange={(e) => setSubmitterName(e.target.value)}
            placeholder="sungjiwon"
            className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
            required
          />
        </div>

        <div>
          <label className="text-sm font-medium text-gray-700 block mb-1">
            스킬 내용 (마크다운) <span className="text-red-500">*</span>
          </label>
          <textarea
            value={skillContent}
            onChange={(e) => setSkillContent(e.target.value)}
            placeholder={`# /my-skill-name\n\n스킬이 하는 일을 설명합니다.\n\n## 사용법\n/my-skill-name [인자]`}
            rows={12}
            className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-500 resize-y"
            required
          />
        </div>

        {status === "error" && (
          <p className="text-red-600 text-sm">제출 실패. 다시 시도해주세요.</p>
        )}

        <button
          type="submit"
          disabled={status === "loading"}
          className="w-full py-2.5 bg-gray-900 text-white rounded-lg text-sm font-medium hover:bg-gray-700 disabled:opacity-50"
        >
          {status === "loading" ? "제출 중..." : "스킬 제출하기"}
        </button>
      </form>
    </div>
  );
}
```

- [ ] **Step 3: 로컬 테스트**

```bash
# http://localhost:3000/submit 접속
# 폼 작성 후 제출 → caramel-team-setup/incoming/ 에 파일 생성 확인
gh api repos/JapanesRamenMaster/caramel-team-setup/contents/incoming --jq '.[].name'
```

---

### Task 9: Vercel 배포

- [ ] **Step 1: vercel.json 작성**

`vercel.json`:
```json
{
  "framework": "nextjs",
  "buildCommand": "npm run build",
  "outputDirectory": ".next"
}
```

- [ ] **Step 2: Vercel 프로젝트 생성 및 환경변수 설정**

```bash
cd ~/Desktop/caramel-skills-catalog
npx vercel --yes

# 환경변수 설정
vercel env add GITHUB_TOKEN production
# 프롬프트: PAT 입력

vercel env add GITHUB_REPO_OWNER production
# 입력: JapanesRamenMaster

vercel env add GITHUB_REPO_NAME production
# 입력: caramel-team-setup
```

- [ ] **Step 3: Production 배포**

```bash
vercel --prod
```

예상 출력: `✅ Production: https://caramel-skills-catalog.vercel.app`

- [ ] **Step 4: Production 확인**

```bash
# 브라우저에서 열기
open https://caramel-skills-catalog.vercel.app

# 확인 항목:
# 1. 스킬 목록 로드됨 (11개)
# 2. 검색 동작
# 3. 스킬 상세 페이지 접근
# 4. 설치 커맨드 복사 동작
# 5. /submit 페이지 폼 표시
```

- [ ] **Step 5: 팀에 URL 공유**

```bash
# Slack #caramel_product 또는 #general에 공유
```

---

### Task 10: /install-skill Claude Code 스킬 (팀원 로컬용)

**Files:**
- Create: `~/.caramel-team-setup/skills/install-skill/SKILL.md`

> 팀원이 Claude Code 안에서 `/install-skill <name>`으로 스킬을 로컬에 설치하게 해주는 스킬.

- [ ] **Step 1: 스킬 파일 작성**

`~/.caramel-team-setup/skills/install-skill/SKILL.md`:
```markdown
---
name: install-skill
description: |
  caramel-team-setup에서 팀 스킬을 로컬 ~/.claude/skills/에 설치.
  Use when: "/install-skill <name>", "스킬 설치", "팀 스킬 가져오기".
scope: team
owner: juseong
side-effects:
  - file-write
disable-model-invocation: false
tags:
  - 스킬
  - 설치
---

# /install-skill — 팀 스킬 로컬 설치

`caramel-team-setup`의 `skills/` 폴더에서 스킬을 로컬 `~/.claude/skills/`에 설치한다.

## 사용법

- `/install-skill zone-change` — zone-change 스킬 설치
- `/install-skill` — 설치 가능한 팀 스킬 목록 표시 후 선택

## 실행 절차

1. 스킬 이름이 주어지면 바로 설치. 없으면 목록 표시.
2. `~/.caramel-team-setup/skills/<name>/SKILL.md` 존재 여부 확인.
3. 있으면: `~/.claude/skills/<name>/SKILL.md`로 복사 (디렉토리 없으면 생성).
4. 완료 메시지 출력.

## 예시 명령어

```bash
# 목록 확인
ls ~/.caramel-team-setup/skills/

# 단일 스킬 설치
mkdir -p ~/.claude/skills/zone-change
cp ~/.caramel-team-setup/skills/zone-change/SKILL.md ~/.claude/skills/zone-change/SKILL.md
echo "✅ zone-change 설치 완료"

# 전체 팀 스킬 동기화 (주의: 로컬 수정 덮어씀)
cp -r ~/.caramel-team-setup/skills/. ~/.claude/skills/
echo "✅ 전체 팀 스킬 동기화 완료"
```
```

- [ ] **Step 2: 검증 + 커밋**

```bash
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/install-skill/SKILL.md
cd ~/.caramel-team-setup
git add skills/install-skill/SKILL.md
git commit -m "feat: /install-skill 스킬 추가"
```
