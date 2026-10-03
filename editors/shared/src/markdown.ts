export type OpenSource = (path: string, line?: number) => Promise<void>;

/** Render an intentionally small Markdown surface without interpreting HTML. */
function inline(parent: HTMLElement, text: string, openSource: OpenSource): void {
    const pattern = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|\[[^\]\n]+\]\([^\s)]+\))/g;
    let cursor = 0;
    for (const match of text.matchAll(pattern)) {
        parent.append(document.createTextNode(text.slice(cursor, match.index)));
        const token = match[0]; let node: HTMLElement;
        if (token.startsWith('`')) { node = document.createElement('code'); node.textContent = token.slice(1, -1); }
        else if (token.startsWith('**')) { node = document.createElement('strong'); node.textContent = token.slice(2, -2); }
        else if (token.startsWith('*')) { node = document.createElement('em'); node.textContent = token.slice(1, -1); }
        else {
            const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(token)!;
            const file = /^([^:#?]+?)(?::(\d+)|#L(\d+))?$/.exec(link[2]);
            if (file && !/^[\/\\]/.test(file[1]) && !file[1].split(/[\/\\]/).includes('..')) {
                const button = document.createElement('button'); button.className = 'source-link'; button.textContent = link[1];
                button.title = link[2]; button.addEventListener('click', () => { void openSource(file[1], Number(file[2] ?? file[3] ?? 1)); }); node = button;
            } else { node = document.createElement('span'); node.textContent = link[1]; node.title = link[2]; }
        }
        parent.append(node); cursor = match.index! + token.length;
    }
    parent.append(document.createTextNode(text.slice(cursor)));
}

export function renderMarkdown(target: HTMLElement, text: string, openSource: OpenSource): void {
    const fragment = document.createDocumentFragment();
    const lines = text.slice(0, 1_000_000).replace(/\r\n/g, '\n').split('\n');
    let list: HTMLUListElement | HTMLOListElement | undefined;
    for (let index = 0; index < lines.length; index++) {
        const line = lines[index];
        if (/^\s*```/.test(line)) {
            list = undefined;
            const language = line.replace(/^\s*```/, '').trim().slice(0, 40); const body: string[] = [];
            while (++index < lines.length && !/^\s*```\s*$/.test(lines[index])) { body.push(lines[index]); }
            const block = document.createElement('section'); block.className = 'code-block';
            const label = document.createElement('div'); label.className = 'code-label'; label.textContent = language || 'Code';
            const pre = document.createElement('pre'); const code = document.createElement('code'); code.textContent = body.join('\n'); pre.append(code);
            block.append(label, pre); fragment.append(block); continue;
        }
        if (!line.trim()) { list = undefined; continue; }
        const heading = /^(#{1,4})\s+(.+)$/.exec(line);
        if (heading) { const node = document.createElement(`h${heading[1].length + 1}`); inline(node, heading[2], openSource); fragment.append(node); list = undefined; continue; }
        const item = /^\s*(?:([-*])|\d+\.)\s+(.+)$/.exec(line);
        if (item) {
            const tag = item[1] ? 'ul' : 'ol';
            if (!list || list.tagName.toLowerCase() !== tag) { list = document.createElement(tag); fragment.append(list); }
            const node = document.createElement('li'); inline(node, item[2], openSource); list.append(node); continue;
        }
        list = undefined;
        if (/^\s*\|/.test(line) && /^\s*\|?\s*:?-{3,}/.test(lines[index + 1] ?? '')) {
            const wrapper = document.createElement('div'); wrapper.className = 'table-scroll'; const table = document.createElement('table');
            const row = (value: string, header: boolean) => {
                const tr = document.createElement('tr');
                for (const cell of value.trim().replace(/^\||\|$/g, '').split('|')) { const td = document.createElement(header ? 'th' : 'td'); inline(td, cell.trim(), openSource); tr.append(td); }
                table.append(tr);
            };
            row(line, true); index++;
            while (/^\s*\|/.test(lines[index + 1] ?? '')) { row(lines[++index], false); }
            wrapper.append(table); fragment.append(wrapper); continue;
        }
        const quote = /^>\s?(.*)$/.exec(line);
        const node = document.createElement(quote ? 'blockquote' : 'p'); inline(node, quote ? quote[1] : line, openSource); fragment.append(node);
    }
    target.replaceChildren(fragment);
}
