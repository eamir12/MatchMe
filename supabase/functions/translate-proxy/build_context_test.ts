import { buildDeepLContext } from './index.ts';

// Minimal fake Supabase client to test buildDeepLContext
function makeFakeClient(matchRow: any, senderGender: string | null, recipientGender: string | null) {
  return {
    from: (table: string) => {
      return {
        select: (cols: string) => {
          return {
            eq: (col: string, val: any) => {
              return {
                maybeSingle: async () => {
                  if (table === 'matches') return { data: matchRow, error: null };
                  return { data: null, error: `unexpected maybeSingle for ${table}` };
                },
                limit: (n:number) => {
                  if (table === 'users') {
                    // determine which user we were queried for
                    if (val === matchRow.user1_id) {
                      return Promise.resolve({ data: [{ id: val, gender: senderGender }], error: null });
                    }
                    if (val === matchRow.user2_id) {
                      return Promise.resolve({ data: [{ id: val, gender: recipientGender }], error: null });
                    }
                    return Promise.resolve({ data: [], error: null });
                  }
                  return Promise.resolve({ data: [], error: null });
                }
              };
            }
          };
        }
      };
    }
  } as any;
}

Deno.test('buildDeepLContext constructs speaker and recipient and count hints', async () => {
  const matchRow = { user1_id: 'u1', user2_id: 'u2' };
  const fakeClient: any = makeFakeClient(matchRow, 'female', 'male');
  const record = { match_id: 'm1', sender_id: 'u1' };
  const text = 'You have 3 new messages.';

  const ctx = await buildDeepLContext(fakeClient, record, text);
  if (!ctx) throw new Error('Expected context but got null');
  if (!ctx.includes('speaker_gender: female')) throw new Error('Missing speaker_gender');
  if (!ctx.includes('recipient_gender: male')) throw new Error('Missing recipient_gender');
  if (!ctx.includes('count: 3')) throw new Error('Missing count');
});
