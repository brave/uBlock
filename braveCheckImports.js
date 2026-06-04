import assert from 'node:assert'
import path from 'node:path'
import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'

function isKnownImportPath(p) {
  return p.startsWith('src/js/resources/') || ['src/js/jsonpath.js', 'src/js/arglist-parser.js', 'src/js/urlskip.js'].includes(p)
}

registerHooks({
  load(url, context, nextLoad) {
    // Shouldn't load any remote files
    assert(url.startsWith('file:///'), `Attempted to import a remote URL [${url}].`)
    const filePath = fileURLToPath(url)
    const relativePath = path.relative(process.cwd(), filePath);
    // Shouldn't load any files outside of the repository root
    assert(!relativePath.startsWith('.'), `Attempted to load [${relativePath}] from outside of the repository root.`)

    // Should be known import path
    assert(isKnownImportPath(relativePath), `New import [${relativePath}] has not been approved.`)

    return nextLoad(url, context)
  },
})

const { builtinScriptlets } = await import('./src/js/resources/scriptlets.js');

assert(Array.isArray(builtinScriptlets), 'Imported scriptlets are not an array.')

console.log('All checks succeeded.')
