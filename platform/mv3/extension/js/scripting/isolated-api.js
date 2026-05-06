/*******************************************************************************

    uBlock Origin Lite - a comprehensive, MV3-compliant content blocker
    Copyright (C) 2022-present Raymond Hill

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see {http://www.gnu.org/licenses/}.

    Home: https://github.com/gorhill/uBlock/

*/

/******************************************************************************/

(api => {
    if ( typeof api === 'object' ) { return; }

    const isolatedAPI = self.isolatedAPI = {};

    isolatedAPI.contexts = {
        entries: [],
        compute() {
            const docloc = document.location;
            const origins = [ docloc.origin ];
            if ( docloc.ancestorOrigins ) {
                origins.push(...docloc.ancestorOrigins);
            }
            this.entries = origins.map((origin, i) => {
                const beg = origin.indexOf('://');
                if ( beg === -1 ) { return; }
                const hn1 = origin.slice(beg+3)
                const end = hn1.indexOf(':');
                const hn2 = end === -1 ? hn1 : hn1.slice(0, end);
                const hnParts = hn2.split('.');
                if ( hn2.length === 0 ) { return; }
                const hns = [];
                for ( let i = 0; i < hnParts.length; i++ ) {
                    hns.push(`${hnParts.slice(i).join('.')}`);
                }
                return { hns, i };
            }).filter(a => a !== undefined);
        },
        get topHostname() {
            if ( this.entries.length === 0 ) { this.compute(); }
            return this.entries.at(-1).hns[0];
        },
        get hostnames() {
            if ( this.entries.length === 0 ) { this.compute(); }
            return this.entries[0].hns;
        },
        get entities() {
            if ( this.entries.length === 0 ) { this.compute(); }
            if ( this.entries[0].ens === undefined ) {
                const ens = [];
                const hnparts =  this.entries[0].hns[0].split('.');
                const n = hnparts.length - 1;
                for ( let i = 0; i < n; i++ ) {
                    for ( let j = n; j > i; j-- ) {
                        ens.push(`${hnparts.slice(i,j).join('.')}.*`);
                    }
                }
                ens.sort((a, b) => {
                    const d = b.length - a.length;
                    if ( d !== 0 ) { return d; }
                    return a > b ? -1 : 1;
                });
                this.entries[0].ens = ens;
            }
            return this.entries[0].ens;
        },
    };

    isolatedAPI.binarySearch = (haystack, needle, r) => {
        let l = 0, i = 0, d = 0, candidate;
        r = r >= 0 ? r : haystack.length;
        while ( l < r ) {
            i = l + r >>> 1;
            candidate = haystack[i];
            d = needle.length - candidate.length;
            if ( d === 0 ) {
                if ( needle === candidate ) { return i; }
                d = needle < candidate ? -1 : 1;
            }
            if ( d < 0 ) {
                r = i;
            } else {
                l = i + 1;
            }
        }
        return ~i;
    };

})(self.isolatedAPI);


(api => {
    if ( typeof api === 'object' ) { return; }

    const cosmeticAPI = self.cosmeticAPI = {};
    const { isolatedAPI } = self;
    const topHostname = isolatedAPI.contexts.topHostname;
    const thisHostname = document.location.hostname || '';

    const sessionRead = async function(key) {
        try {
            const bin = await chrome.storage.session.get(key);
            return bin?.[key] ?? undefined;
        } catch {
        }
    };

    const sessionWrite = function(key, data) {
        try {
            chrome.storage.session.set({ [key]: data });
        } catch {
        }
    };

    const localRead = async function(key) {
        try {
            const bin = await chrome.storage.local.get(key);
            return bin?.[key] ?? undefined;
        } catch {
        }
    };

    const selectorsFromListIndex = (data, ilist) => {
        const list = JSON.parse(`[${data.selectorLists[ilist]}]`);
        const { result } = data;
        for ( const iselector of list ) {
            if ( iselector >= 0 ) {
                result.selectors.add(data.selectors[iselector]);
            } else {
                result.exceptions.add(data.selectors[~iselector]);
            }
        }
    };

    const selectorsFromHostnames = (haystack, needles, data) => {
        let listref = -1;
        for ( const needle of needles ) {
            listref = isolatedAPI.binarySearch(haystack, needle, listref);
            if ( listref >= 0 ) {
                selectorsFromListIndex(data, data.selectorListRefs[listref]);
            } else {
                listref = ~listref;
            }
        }
    };

    const selectorsFromRuleset = async (realm, rulesetId, result) => {
        const data = await localRead(`css.${realm}.${rulesetId}`);
        if ( typeof data !== 'object' || data === null ) { return; }
        data.result = result;
        selectorsFromHostnames(data.hostnames, isolatedAPI.contexts.hostnames, data);
        if ( data.hasEntities ) {
            selectorsFromHostnames(data.hostnames, isolatedAPI.contexts.entities, data);
        }
        const { regexes } = data;
        for ( let i = 0, n = regexes.length; i < n; i += 3 ) {
            if ( thisHostname.includes(regexes[i+0]) === false ) { continue; }
            if ( typeof regexes[i+1] === 'string' ) {
                regexes[i+1] = new RegExp(regexes[i+1]);
            }
            if ( regexes[i+1].test(thisHostname) === false ) { continue; }
            selectorsFromListIndex(data, regexes[i+2]);
        }
    };

    const fillCache = async function(realm, rulesetIds) {
        const selectors = new Set();
        const exceptions = new Set();
        const result = { selectors, exceptions };
        const [ filteringModeDetails ] = await Promise.all([
            localRead('filteringModeDetails'),
            ...rulesetIds.map(a => selectorsFromRuleset(realm, a, result)),
        ]);
        const skip = filteringModeDetails?.none.some(a => {
            if ( topHostname.endsWith(a) === false ) { return false; }
            const n = a.length;
            return topHostname.length === n || topHostname.at(-n-1) === '.';
        });
        for ( const selector of exceptions ) {
            selectors.delete(selector);
        }
        if ( skip ) {
            selectors.clear();
        }
        cacheEntry[realm.charAt(0)] = Array.from(selectors).map(a =>
            a.startsWith('{') ? JSON.parse(a) : a
        );
    };

    const readCache = async ( ) => {
        cacheEntry = await sessionRead(cacheKey) || {};
    };

    const cacheKey =
        `cache.css.${topHostname !== thisHostname ? `${topHostname}/` : ''}${thisHostname || ''}`;
    let clientCount = 0;
    let cacheEntry;

    cosmeticAPI.getSelectors = async function(realm, rulesetIds) {
        clientCount += 1;
        const slot = realm.charAt(0);
        if ( cacheEntry === undefined ) {
            cacheEntry = readCache();
        }
        if ( cacheEntry instanceof Promise ) {
            await cacheEntry;
        }
        if ( cacheEntry[slot] === undefined ) {
            cacheEntry[slot] = fillCache(realm, rulesetIds);
        }
        if ( cacheEntry[slot] instanceof Promise ) {
            await cacheEntry[slot];
        }
        return cacheEntry[slot];
    };

    cosmeticAPI.release = function() {
        clientCount -= 1;
        if ( clientCount !== 0 ) { return; }
        self.cosmeticAPI = undefined;
        const now = Math.round(Date.now() / 15000);
        const since = now - (cacheEntry.t || 0);
        if ( since <= 1 ) { return; }
        cacheEntry.t = now;
        sessionWrite(cacheKey, cacheEntry);
    };
})(self.cosmeticAPI);

/******************************************************************************/

void 0;