import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { KEY_BACKGROUND_KEEP_ALIVE, setBoolean } from '../store/AppSettings';
import { logE, logI } from '../util/log';

// 后台保活：只有用户在「省电 → 后台持续运行」里主动打开才申请。
//
// 用 TASK_KEEPING 而不是 dataTransfer/audioPlayback 等业务型长时任务：
//   · TASK_KEEPING 的语义就是「保持进程运行」，不要求伪造下载/播放/定位；
//   · dataTransfer 要求持续更新进度、10 分钟不动会被系统取消，拿它冒充常驻
//     既不符合规范，也会在通知栏留下「正在运行数据传输任务」的假文案。
//
// 真机边界（已用最小探针验证）：平板可以直接启动；部分手机返回 9800005
// 「Current device can not request continuous tasks of the TASK_KEEPING type」。
// 这不是签名问题，是设备形态/系统策略；失败时如实回退为关闭，不偷偷换类型。
export interface KeepAliveResult {
  ok: boolean;
  code: number;
  message: string;
}

class BackgroundKeepAlive {
  private context: common.UIAbilityContext | null = null;
  private running: boolean = false;
  private cancelHandler: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | null = null;

  // 在 EntryAbility.onCreate 里尽早注入上下文。重复调用是幂等的。
  init(context: common.UIAbilityContext): void {
    this.context = context;
    if (this.cancelHandler !== null) {
      return;
    }
    this.cancelHandler = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      // 用户从通知栏移除、系统回收、或系统策略取消：任务已经不在了，开关必须
      // 跟着变成关闭，否则下次启动会误以为还在保活。
      this.running = false;
      logI(`[BackgroundKeepAlive] cancelled reason=${info.reason} id=${info.id}`);
      setBoolean(KEY_BACKGROUND_KEEP_ALIVE, false);
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelHandler);
    } catch (e) {
      // 没有权限或系统版本不支持监听：不影响主动 start/stop。
      logE(`[BackgroundKeepAlive] on(continuousTaskCancel) failed: ${(e as BusinessError).message}`);
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  async start(): Promise<KeepAliveResult> {
    if (this.running) {
      return { ok: true, code: 0, message: '' };
    }
    const context = this.context;
    if (context === null) {
      return { ok: false, code: -1, message: 'ability context is not ready' };
    }
    try {
      const agent: WantAgent = await this.buildAgent(context);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      this.running = true;
      logI('[BackgroundKeepAlive] TASK_KEEPING started');
      return { ok: true, code: 0, message: '' };
    } catch (e) {
      const err = e as BusinessError;
      this.running = false;
      const code: number = err.code ?? -1;
      const message: string = err.message ?? `${e}`;
      logE(`[BackgroundKeepAlive] start failed code=${code} message=${message}`);
      return { ok: false, code: code, message: message };
    }
  }

  async stop(): Promise<void> {
    const context = this.context;
    this.running = false;
    if (context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      logI('[BackgroundKeepAlive] TASK_KEEPING stopped');
    } catch (e) {
      // 已经不在运行（例如用户先从通知栏取消）时这里会报错，属正常收尾。
      logE(`[BackgroundKeepAlive] stop failed: ${(e as BusinessError).message}`);
    }
  }

  private async buildAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.applicationInfo.name,
        abilityName: context.abilityInfo.name,
        parameters: { 'keepAlive': 1 }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 7301,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }
}

export const backgroundKeepAlive: BackgroundKeepAlive = new BackgroundKeepAlive();
