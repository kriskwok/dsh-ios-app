(function() {
  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();
  var bg3 = style.getPropertyValue('--bg3').trim();
  var warn = style.getPropertyValue('--warn').trim();
  var danger = style.getPropertyValue('--danger').trim();

  // Chart 1: Priority distribution
  var chartPriority = echarts.init(document.getElementById('chart-priority'), null, { renderer: 'svg' });
  chartPriority.setOption({
    animation: false,
    tooltip: {
      trigger: 'item',
      appendToBody: true,
      formatter: '{b}: {c} 项 ({d}%)'
    },
    legend: {
      bottom: 0,
      textStyle: { color: muted, fontSize: 12 },
      itemWidth: 12,
      itemHeight: 12,
      icon: 'circle'
    },
    series: [{
      type: 'pie',
      radius: ['45%', '70%'],
      center: ['50%', '42%'],
      avoidLabelOverlap: true,
      itemStyle: {
        borderColor: bg2,
        borderWidth: 3
      },
      label: {
        show: true,
        color: ink,
        fontSize: 13,
        fontWeight: 600,
        formatter: '{c}'
      },
      data: [
        { value: 3, name: 'P0 紧急', itemStyle: { color: danger } },
        { value: 4, name: 'P1 高优先级', itemStyle: { color: warn } },
        { value: 3, name: 'P2 中优先级', itemStyle: { color: accent } },
        { value: 2, name: 'P3 改善型', itemStyle: { color: muted } }
      ]
    }]
  });
  window.addEventListener('resize', function() { chartPriority.resize(); });

  // Chart 2: Source file LOC
  var chartLOC = echarts.init(document.getElementById('chart-loc'), null, { renderer: 'svg' });
  chartLOC.setOption({
    animation: false,
    tooltip: {
      trigger: 'axis',
      appendToBody: true,
      axisPointer: { type: 'shadow' },
      formatter: function(params) {
        var p = params[0];
        return p.name + '<br/>行数: ' + p.value + ' 行';
      }
    },
    grid: {
      left: '3%',
      right: '8%',
      bottom: '3%',
      top: '8%',
      containLabel: true
    },
    xAxis: {
      type: 'value',
      max: 1000,
      axisLine: { lineStyle: { color: rule } },
      axisLabel: { color: muted, fontSize: 11 },
      splitLine: { lineStyle: { color: rule, type: 'dashed' } }
    },
    yAxis: {
      type: 'category',
      data: [
        'DSHIOSAppApp.swift',
        'AgentLogoView.swift',
        'AgentGatewayFactory.swift',
        'ServerEditorView.swift',
        'ServerListView.swift',
        'AppShellViewModel.swift',
        'ServerProfile.swift',
        'ConversationMessage.swift',
        'AgentModels.swift',
        'DSHProtocol.swift',
        'DSHAPIClient.swift',
        'HermesRPCClient.swift',
        'DSHAgentGateway.swift',
        'HermesAgentGateway.swift',
        'HermesNativeAuth.swift',
        'ChatSessionViewModel.swift',
        'DSHUIView.swift',
        'AppShellView.swift',
        'ChatSessionView.swift'
      ],
      axisLine: { lineStyle: { color: rule } },
      axisLabel: {
        color: function(value) {
          var num = parseInt(value);
          if (num >= 500) return danger;
          if (num >= 300) return warn;
          return ink;
        },
        fontSize: 10.5,
        fontFamily: 'JetBrainsMono, monospace'
      }
    },
    series: [{
      type: 'bar',
      data: [
        { value: 22, itemStyle: { color: accent2 } },
        { value: 30, itemStyle: { color: accent2 } },
        { value: 13, itemStyle: { color: accent2 } },
        { value: 114, itemStyle: { color: accent2 } },
        { value: 115, itemStyle: { color: accent2 } },
        { value: 120, itemStyle: { color: accent2 } },
        { value: 132, itemStyle: { color: accent2 } },
        { value: 216, itemStyle: { color: accent2 } },
        { value: 208, itemStyle: { color: accent2 } },
        { value: 250, itemStyle: { color: accent2 } },
        { value: 219, itemStyle: { color: accent2 } },
        { value: 283, itemStyle: { color: accent2 } },
        { value: 283, itemStyle: { color: accent2 } },
        { value: 333, itemStyle: { color: warn } },
        { value: 382, itemStyle: { color: warn } },
        { value: 428, itemStyle: { color: warn } },
        { value: 538, itemStyle: { color: danger } },
        { value: 579, itemStyle: { color: danger } },
        { value: 918, itemStyle: { color: danger } }
      ],
      barWidth: '55%',
      label: {
        show: true,
        position: 'right',
        color: ink,
        fontSize: 11,
        fontFamily: 'JetBrainsMono, monospace',
        formatter: '{c}'
      },
      markLine: {
        symbol: 'none',
        data: [{
          xAxis: 500,
          lineStyle: { color: danger, type: 'dashed', width: 1.5 },
          label: {
            show: true,
            formatter: '500 行警戒线',
            color: danger,
            fontSize: 10,
            position: 'insideEndTop'
          }
        }]
      }
    }]
  });
  window.addEventListener('resize', function() { chartLOC.resize(); });
})();
