import { FamilyInvite } from '../model/CarbonModels';

/**
 * 「收到家庭邀请」的提醒规则。
 *
 * 抽成纯函数放在 common/ 下：不碰 UI、不碰定时器、不读全局状态，
 * 这样回归脚本可以直接跑它（见 tools/verify-logic.mjs 的家庭邀请提醒用例）。
 *
 * 规则：
 *   1. 未登录不弹——家庭属于账号，连账号都没有时提醒了也没法同意；
 *   2. 已经有家庭不弹——服务端一般不会再给你发邀请，这里再兜一层；
 *   3. 同一条邀请只弹一次——弹过一次就记住 inviteId，避免 20 秒后又弹同一条；
 *   4. 多条未处理的邀请，按服务端返回顺序（新的在前）取第一条没弹过的。
 */
export function pickInviteToAlert(incoming: FamilyInvite[], shown: string[],
  hasFamily: boolean, loggedIn: boolean): FamilyInvite | null {
  if (!loggedIn || hasFamily) {
    return null;
  }
  for (let i = 0; i < incoming.length; i++) {
    const inv = incoming[i];
    if (inv.inviteId.length === 0) {
      continue;
    }
    if (shown.indexOf(inv.inviteId) >= 0) {
      continue;
    }
    return inv;
  }
  return null;
}

/** 邀请人的显示名：昵称优先，没有昵称退回账号，都没有就写「有人」 */
export function inviteAlertWho(inv: FamilyInvite): string {
  if (inv.nickname.length > 0) {
    return inv.nickname;
  }
  if (inv.username.length > 0) {
    return inv.username;
  }
  return '有人';
}

/** 弹窗正文：区分「拉你进他的家庭」和「和你一起新建家庭」两种情况 */
export function inviteAlertText(inv: FamilyInvite): string {
  const who = inviteAlertWho(inv);
  const fam = inv.familyName.length > 0 ? inv.familyName : 'TA 的家庭';
  if (inv.hasFamily) {
    return `${who} 邀请你加入「${fam}」，同意后就能看到全家人的减排。`;
  }
  return `${who} 想和你一起组建「${fam}」，同意后家庭立即建立。`;
}
